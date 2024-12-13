/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

#include <algorithm>
#include <cstdio>
#include <cfu.h>

#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"

namespace tflite {
namespace reference_integer_ops {

// Fixed-point per-channel-quantization convolution reference kernel.
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {
  // Get parameters.
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t output_offset = params.output_offset;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);

  const int patch_size = filter_height * filter_width * filter_input_depth;
  const int patch_num = output_height * output_width;
  const int32_t input_offset = params.input_offset;
  printf("patch_num: %d, patch_size: %d, output_depth: %d\n",patch_num,patch_size,output_depth);
  // printf("input offset: %ld\n",params.input_offset);
  int8_t im2col[1024][576];
  int8_t kernel[576][64];
  int32_t matmul[1024][64];
  // int32_t matmul_old[1024][64];
  for (int i = 0; i < patch_num; i++)
    for (int j = 0; j < patch_size; j++)
        im2col[i][j] = -input_offset;
  for (int out_y = 0; out_y < output_height; ++out_y) {
    const int in_y_origin = (out_y * stride_height) - pad_height;
    for (int out_x = 0; out_x < output_width; ++out_x) {
      const int in_x_origin = (out_x * stride_width) - pad_width;
      for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
        const int in_y = in_y_origin + dilation_height_factor * filter_y;
        for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
          const int in_x = in_x_origin + dilation_width_factor * filter_x;

          // Zero padding by omitting the areas outside the image.
          const bool is_point_inside_image =
            (in_x >= 0) && (in_x < input_width) && (in_y >= 0) && (in_y < input_height);

          if (!is_point_inside_image) continue;

          for (int in_channel = 0; in_channel < filter_input_depth; ++in_channel) {
            im2col[out_y * output_width + out_x]
            [filter_y * filter_width * filter_input_depth + filter_x * filter_input_depth + in_channel]
            = input_data[Offset(input_shape, 0, in_y, in_x, in_channel)];
          }
        }
      }
    }
  }

  for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
    for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
      for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
        for (int in_channel = 0; in_channel < filter_input_depth; ++in_channel) {
          kernel[filter_y * filter_width * filter_input_depth + filter_x * filter_input_depth + in_channel]
          [out_channel] = filter_data[Offset(filter_shape, out_channel, filter_y, filter_x, in_channel)];
        }
      }
    }
  }
  // matmul
  // for (int i = 0; i < patch_num; ++i) {
  //   for (int j = 0; j < output_depth; ++j) {
  //     int32_t acc = 0;
  //     for (int k = 0; k < patch_size; ++k)
  //       acc += (im2col[i][k] + input_offset) * kernel[k][j];
  //     matmul_old[i][j] = acc;
  //   }
  // }
  // const int tile_size = std::min(output_depth, patch_num);
  const int tile_size = 64;
  const int32_t KMN = ((int32_t)patch_size << 21) | ((int32_t)tile_size << 9) | (int32_t)tile_size;
  // printf("KMN: %ld\n",KMN);
  for (int i = 0; i < patch_num; i += tile_size) {
    for (int j = 0; j < output_depth; j += tile_size) {
      for (int q = 0; q < tile_size; q += 4) {
        for (int k = 0; k < patch_size; ++k){
          cfu_op0(0, ((uint32_t)(uint8_t)im2col[i+q][k] << 24) | ((uint32_t)(uint8_t)im2col[i+q+1][k] << 16) | ((uint32_t)(uint8_t)im2col[i+q+2][k] << 8) | (uint32_t)(uint8_t)im2col[i+q+3][k], (q>>2)*patch_size+k);
          cfu_op0(1, ((uint32_t)(uint8_t)kernel[k][j+q] << 24) | ((uint32_t)(uint8_t)kernel[k][j+q+1] << 16) | ((uint32_t)(uint8_t)kernel[k][j+q+2] << 8) | (uint32_t)(uint8_t)kernel[k][j+q+3], (q>>2)*patch_size+k);
        }
      }
      cfu_op0(3, KMN, input_offset);
      for (int m = 0; m < tile_size; ++m){
        for (int n = 0; n < tile_size; ++n){
          if(i+m < patch_num && j+n < output_depth){
            matmul[i+m][j+n] = cfu_op0(2, n % 4, (n >> 2) * tile_size + m);
            // if(matmul[i+m][j+n] != matmul_old[i+m][j+n])
            //   printf("i: %d,j: %d, predict : %ld, label : %ld\n",i+m,j+n,matmul[i+m][j+n], matmul_old[i+m][j+n]);
          }
        }
      }
    }
  }

  // const int32_t KMN = ((int32_t)patch_size << 21) | ((int32_t)patch_num << 9) | (int32_t)output_depth; //11, 12, 9
  // for (int i = 0; i < patch_num; i += 4) {
  //   for (int j = 0; j < patch_size; ++j) {
  //     cfu_op0(0, ((uint32_t)(uint8_t)im2col[i][j]<<24) | ((uint32_t)(uint8_t)im2col[i+1][j]<<16) | ((uint32_t)(uint8_t)im2col[i+2][j]<<8) | (uint32_t)(uint8_t)im2col[i+3][j], (i>>2)*patch_size+j);
  //   }
  // }
  // for (int j = 0; j < output_depth; j += 4) {
  //   for (int i = 0; i < patch_size; ++i) {
  //     cfu_op0(1, ((uint32_t)(uint8_t)kernel[i][j]<<24) | ((uint32_t)(uint8_t)kernel[i][j+1]<<16) | ((uint32_t)(uint8_t)kernel[i][j+2]<<8) | (uint32_t)(uint8_t)kernel[i][j+3], (j>>2)*patch_size+i);
  //   }
  // }
  // cfu_op0(3, KMN, input_offset);
  // for (int i = 0; i < patch_num; ++i)
  //   for (int j = 0; j < output_depth; ++j){
  //     matmul[i][j] = cfu_op0(2, j % 4, (j >> 2) * patch_num + i);
  //   }

  for (int out_y = 0; out_y < output_height; ++out_y) {
    for (int out_x = 0; out_x < output_width; ++out_x) {
      for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
        int32_t acc = matmul[out_y * output_width + out_x][out_channel];
        //  acc = matmul_old[out_y * output_width + out_x][out_channel];

        if (bias_data) {
          acc += bias_data[out_channel];
        }

        acc = MultiplyByQuantizedMultiplier(
            acc, output_multiplier[out_channel], output_shift[out_channel]);
        acc += output_offset;

        acc = std::max(acc, output_activation_min);
        acc = std::min(acc, output_activation_max);

        output_data[Offset(output_shape, 0, out_y, out_x, out_channel)] =
            static_cast<int8_t>(acc);
      }
    }
  }
}

inline void ConvPerChannelWithPackedInt4Weights(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_input, int8_t* unpacked_filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  TFLITE_DCHECK(unpacked_filter_data != nullptr);
  tflite::tensor_utils::UnpackDenseInt4IntoInt8(
      filter_input, filter_shape.FlatSize(), unpacked_filter_data);
  ConvPerChannel(params, output_multiplier, output_shift, input_shape,
                 input_data, filter_shape, unpacked_filter_data, bias_shape,
                 bias_data, output_shape, output_data);
}

// Fixed-point per-channel-quantization convolution reference kernel.
// 16-bit data and 8-bit filter
template <typename AccumScalar>
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int16_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const AccumScalar* bias_data, const RuntimeShape& output_shape,
    int16_t* output_data) {
  // Get parameters.
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          auto group = out_channel / filters_per_group;
          AccumScalar acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;

              // Zero padding by omitting the areas outside the image.
              const bool is_point_inside_image =
                  (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                  (in_y < input_height);

              if (!is_point_inside_image) {
                continue;
              }

              for (int in_channel = 0; in_channel < filter_input_depth;
                   ++in_channel) {
                int32_t input_val =
                    input_data[Offset(input_shape, batch, in_y, in_x,
                                      in_channel + group * filter_input_depth)];
                int32_t filter_val = filter_data[Offset(
                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                // Accumulate with 64 bits accumulator.
                // int64_t += int8_t * int16_t so the highest value we can
                // get from each accumulation is [-127, 127] * ([-32768,
                // 32767] -
                // [-32768, 32767]), which is [-8322945, 8322945].
                // log2(8322945) = 22.99.
                acc += filter_val * input_val;
              }
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          int32_t scaled_acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          scaled_acc = std::max(scaled_acc, output_activation_min);
          scaled_acc = std::min(scaled_acc, output_activation_max);
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              static_cast<int16_t>(scaled_acc);
        }
      }
    }
  }
}

}  // namespace reference_integer_ops
}  // namespace tflite

#endif  // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
