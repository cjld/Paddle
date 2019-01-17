/* Copyright (c) 2018 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <boost/preprocessor/repetition/repeat.hpp>
#include "cub/cub.cuh"
#include "paddle/fluid/operators/group_norm_op.h"
#include "paddle/fluid/platform/cuda_device_function.h"

namespace paddle {
namespace operators {

enum Flags { kHasScale = 1, kHasBias = 2, kHasDx = 4 };

template <typename T>
__device__ __inline__ void CudaAtomicAddWithWarp(T* sum, T value) {
  typedef cub::WarpReduce<T> WarpReduce;
  typename WarpReduce::TempStorage temp_storage;
  value = WarpReduce(temp_storage).Sum(value);
  if (cub::LaneId() == 0) platform::CudaAtomicAdd(sum, value);
}

template <typename T>
__global__ void GroupNormForwardGetMeanAndVar(const T* x, int N, int C,
                                              int imsize, int groups,
                                              int group_size, T* mean, T* var) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int number = min(group_size, static_cast<int>(C - gid * group_size));
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_mean = 0, x_var = 0;
  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T val = x[(bid * C + ccid) * imsize + imid];
    x_mean += val;
    x_var += val * val;
  }
  x_mean /= number * imsize;
  x_var /= number * imsize;
  CudaAtomicAddWithWarp(&mean[bid * groups + gid], x_mean);
  CudaAtomicAddWithWarp(&var[bid * groups + gid], x_var);
}

template <typename T, int flags>
__global__ void GroupNormForward(const T* x, const T* mean, const T* var,
                                 const T* scale, const T* bias, int N, int C,
                                 int imsize, int groups, int group_size,
                                 T epsilon, T* y, T* real_var) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_mean = mean[bid * groups + gid];
  T x_var = var[bid * groups + gid];
  x_var = x_var - x_mean * x_mean;
  T var_inv = 1.0 / sqrt(x_var + epsilon);
  if (cid == 0 && threadIdx.x == 0) real_var[bid * groups + gid] = x_var;
  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T val = x[(bid * C + ccid) * imsize + imid];
    val = (val - x_mean) * var_inv;
    if (flags & kHasScale) val *= scale[gid * group_size + cid];
    if (flags & kHasBias) val += bias[gid * group_size + cid];
    y[(bid * C + ccid) * imsize + imid] = val;
  }
}

template <typename T>
class GroupNormKernel<platform::CUDADeviceContext, T>
    : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    const float epsilon = ctx.Attr<float>("epsilon");
    auto* scale = ctx.Input<Tensor>("Scale");
    auto* bias = ctx.Input<Tensor>("Bias");
    auto* x = ctx.Input<Tensor>("X");

    auto* y = ctx.Output<Tensor>("Y");
    auto* mean = ctx.Output<Tensor>("Mean");
    auto* var = ctx.Output<Tensor>("Variance");
    const auto groups = ctx.Attr<int>("groups");

    const auto x_dims = x->dims();
    const int group_size = (x_dims[1] - 1) / groups + 1;

    y->mutable_data<T>(ctx.GetPlace());
    mean->mutable_data<T>(ctx.GetPlace());
    var->mutable_data<T>(ctx.GetPlace());
    math::SetConstant<platform::CUDADeviceContext, T> set_zero;
    auto& dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    Tensor temp_var;
    temp_var.mutable_data<T>(var->dims(), ctx.GetPlace());

    set_zero(dev_ctx, mean, static_cast<T>(0));
    set_zero(dev_ctx, &temp_var, static_cast<T>(0));

    auto* x_data = x->data<T>();
    auto* y_data = y->data<T>();
    auto* mean_data = mean->data<T>();
    auto* var_data = var->data<T>();
    auto* temp_var_data = temp_var.data<T>();

    const T* scale_data = nullptr;
    if (scale) scale_data = scale->data<T>();
    const T* bias_data = nullptr;
    if (bias) bias_data = bias->data<T>();

    int imsize = x_dims[2] * x_dims[3];
    int block_size = std::min(1024, imsize);
    dim3 grid(group_size, groups, x_dims[0]);
    dim3 threads(block_size, 1, 1);
    GroupNormForwardGetMeanAndVar<T><<<grid, threads, 0, dev_ctx.stream()>>>(
        x_data, x_dims[0], x_dims[1], imsize, groups, group_size, mean_data,
        temp_var_data);
    int flags =
        (scale_data != nullptr) * kHasScale + (bias_data != nullptr) * kHasBias;
#define CALL(z, i, _)                                                       \
  if (i == flags) {                                                         \
    GroupNormForward<T, i><<<grid, threads, 0, dev_ctx.stream()>>>(         \
        x_data, mean_data, temp_var_data, scale_data, bias_data, x_dims[0], \
        x_dims[1], imsize, groups, group_size, epsilon, y_data, var_data);  \
  }
    // NOTE(liangdun): Using boost macro to unroll all cases:
    // 0 for no scale, no bias
    // 1 for has scale, no bias
    // 2 for no scale, has bias
    // 3 for has scale, has bias
    BOOST_PP_REPEAT(4, CALL, _);
#undef CALL
  }
};

template <typename T, int flags>
__global__ void GroupNormBackwardGetMeanAndVar(const T* x, const T* scale,
                                               const T* bias, const T* d_y,
                                               int N, int C, int imsize,
                                               int groups, int group_size,
                                               T epsilon, T* d_mean, T* d_var,
                                               T* d_scale, T* d_bias) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int number = min(group_size, static_cast<int>(C - gid * group_size));
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_scale = (flags & kHasScale) ? scale[ccid] : 1;
  T x_bias = (flags & kHasBias) ? bias[ccid] : 0;
  T x_scale_inv = 0;
  if (x_scale != 0) x_scale_inv = 1.0 / x_scale;
  T d_mean_data = 0, d_var_data = 0, d_scale_data = 0, d_bias_data = 0;

  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T val = x[(bid * C + ccid) * imsize + imid] - x_bias;
    T dval = d_y[(bid * C + ccid) * imsize + imid];

    d_var_data += val * dval;
    d_mean_data += dval * x_scale;

    val = val * x_scale_inv;
    d_bias_data += dval;
    d_scale_data += val * dval;
  }
  CudaAtomicAddWithWarp(&d_mean[bid * groups + gid], d_mean_data);
  CudaAtomicAddWithWarp(&d_var[bid * groups + gid], d_var_data);
  if (flags & kHasScale) CudaAtomicAddWithWarp(&d_scale[ccid], d_scale_data);
  if (flags & kHasBias) CudaAtomicAddWithWarp(&d_bias[ccid], d_bias_data);
}

template <typename T, int flags>
__global__ void GroupNormBackward(const T* x, const T* d_y, const T* scale,
                                  const T* bias, const T* var, const T* d_mean,
                                  const T* d_var, int N, int C, int imsize,
                                  int groups, int group_size, T epsilon,
                                  T* d_x) {
  int gid = blockIdx.y;
  int cid = blockIdx.x;
  int bid = blockIdx.z;
  int number = min(group_size, static_cast<int>(C - gid * group_size));
  int ccid = gid * group_size + cid;
  if (ccid >= C) return;
  T x_var = var[bid * groups + gid];
  T d_x_mean = d_mean[bid * groups + gid];
  T d_x_var = d_var[bid * groups + gid];

  T x_var_inv = 1.0 / sqrt(x_var + epsilon);
  T number_inv = 1.0 / (number * imsize);

  T x_scale = (flags & kHasScale) ? scale[ccid] : 1;
  T x_bias = (flags & kHasBias) ? bias[ccid] : 0;
  T x_scale_inv = 0;
  if (x_scale != 0) x_scale_inv = 1.0 / x_scale;

  for (int imid = threadIdx.x; imid < imsize; imid += blockDim.x) {
    T tmp = x[(bid * C + ccid) * imsize + imid];
    T v_y = (tmp - x_bias) * x_scale_inv;
    T dly = d_y[(bid * C + ccid) * imsize + imid];
    d_x[(bid * C + ccid) * imsize + imid] =
        x_var_inv *
        (dly * x_scale - number_inv * d_x_var * v_y - number_inv * d_x_mean);
  }
}

template <typename T>
class GroupNormGradKernel<platform::CUDADeviceContext, T>
    : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext& ctx) const override {
    const float epsilon = ctx.Attr<float>("epsilon");
    auto* x = ctx.Input<Tensor>("Y");
    auto* var = ctx.Input<Tensor>("Variance");
    auto* scale = ctx.Input<Tensor>("Scale");
    auto* bias = ctx.Input<Tensor>("Bias");
    auto* d_y = ctx.Input<Tensor>(framework::GradVarName("Y"));
    const auto groups = ctx.Attr<int>("groups");

    // init output
    auto* d_x = ctx.Output<Tensor>(framework::GradVarName("X"));
    auto* d_scale = ctx.Output<Tensor>(framework::GradVarName("Scale"));
    auto* d_bias = ctx.Output<Tensor>(framework::GradVarName("Bias"));

    const auto& x_dims = x->dims();
    const int group_size = (x_dims[1] - 1) / groups + 1;

    d_x->mutable_data<T>(ctx.GetPlace());
    math::SetConstant<platform::CUDADeviceContext, T> set_zero;
    auto& dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();

    Tensor temp_var;
    temp_var.mutable_data<T>(var->dims(), ctx.GetPlace());
    set_zero(dev_ctx, &temp_var, static_cast<T>(0));
    T* temp_var_data = temp_var.data<T>();

    Tensor temp_mean;
    temp_mean.mutable_data<T>(var->dims(), ctx.GetPlace());
    set_zero(dev_ctx, &temp_mean, static_cast<T>(0));
    T* temp_mean_data = temp_mean.data<T>();

    auto* x_data = x->data<T>();
    T* d_x_data = nullptr;
    if (d_x) d_x_data = d_x->data<T>();
    auto* y_data = d_y->data<T>();
    auto* var_data = var->data<T>();
    T* d_scale_data = nullptr;
    if (d_scale) {
      d_scale->mutable_data<T>(ctx.GetPlace());
      set_zero(dev_ctx, d_scale, static_cast<T>(0));
      d_scale_data = d_scale->data<T>();
    }
    T* d_bias_data = nullptr;
    if (d_bias) {
      d_bias->mutable_data<T>(ctx.GetPlace());
      set_zero(dev_ctx, d_bias, static_cast<T>(0));
      d_bias_data = d_bias->data<T>();
    }

    const T* scale_data = nullptr;
    if (scale) scale_data = scale->data<T>();
    const T* bias_data = nullptr;
    if (bias) bias_data = bias->data<T>();

    int imsize = x_dims[2] * x_dims[3];
    int block_size = std::min(1024, imsize);
    dim3 grid(group_size, groups, x_dims[0]);
    dim3 threads(block_size, 1, 1);
    int flags =
        (scale_data != nullptr) * kHasScale + (bias_data != nullptr) * kHasBias;

#define CALL(z, i, _)                                                          \
  if (i == flags) {                                                            \
    GroupNormBackwardGetMeanAndVar<T,                                          \
                                   i><<<grid, threads, 0, dev_ctx.stream()>>>( \
        x_data, scale_data, bias_data, y_data, x_dims[0], x_dims[1], imsize,   \
        groups, group_size, epsilon, temp_mean_data, temp_var_data,            \
        d_scale_data, d_bias_data);                                            \
  }
    BOOST_PP_REPEAT(4, CALL, _);
#undef CALL

    if (d_x_data != nullptr) {
#define CALL(z, i, _)                                                    \
  if (i == flags) {                                                      \
    GroupNormBackward<T, 3><<<grid, threads, 0, dev_ctx.stream()>>>(     \
        x_data, y_data, scale_data, bias_data, var_data, temp_mean_data, \
        temp_var_data, x_dims[0], x_dims[1], imsize, groups, group_size, \
        epsilon, d_x_data);                                              \
  }
      BOOST_PP_REPEAT(4, CALL, _);
#undef CALL
    }
    /*

    GroupNormBackwardGetMeanAndVar<T, 3><<<grid, threads, 0,
    dev_ctx.stream()>>>(
        x_data, scale_data, bias_data, y_data, x_dims[0], x_dims[1], imsize,
        groups, group_size, epsilon, temp_mean_data, temp_var_data,
        d_scale_data, d_bias_data);
    GroupNormBackward<T, 3><<<grid, threads, 0, dev_ctx.stream()>>>(
        x_data, y_data, scale_data, bias_data, var_data, temp_mean_data,
        temp_var_data, x_dims[0], x_dims[1], imsize, groups, group_size,
        epsilon, d_x_data);
    */
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
REGISTER_OP_CUDA_KERNEL(
    group_norm,
    ops::GroupNormKernel<paddle::platform::CUDADeviceContext, float>,
    ops::GroupNormKernel<paddle::platform::CUDADeviceContext, double>);
REGISTER_OP_CUDA_KERNEL(
    group_norm_grad,
    ops::GroupNormGradKernel<paddle::platform::CUDADeviceContext, float>,
    ops::GroupNormGradKernel<paddle::platform::CUDADeviceContext, double>);
