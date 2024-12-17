// Copyright 2021 The CFU-Playground Authors
// Copyright 2024 Wei-Ming Huang
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "global_buffer_bram.v"
`include "TPU.v"
module Cfu (
  input               cmd_valid,
  output              cmd_ready,
  input      [9:0]    cmd_payload_function_id,
  input      [31:0]   cmd_payload_inputs_0,
  input      [31:0]   cmd_payload_inputs_1,
  output              rsp_valid,
  input               rsp_ready,
  output     [31:0]   rsp_payload_outputs_0,
  input               reset,
  input               clk
);
  localparam A_bits = 15;
  localparam B_bits = 14;
  localparam C_bits = 13;
  wire A_wr_en = cmd_valid && cmd_ready && cmd_payload_function_id[5:3] == func_write_a;
  wire [A_bits-1:0]A_index = (state == STATE_CALC)? tpu_A_index:cmd_payload_inputs_1[A_bits-1:0];
  wire [A_bits-1:0]tpu_A_index;
  wire [31:0]A_data_out;
  wire B_wr_en = cmd_valid && cmd_ready && cmd_payload_function_id[5:3] == func_write_b;
  wire [B_bits-1:0]B_index = (state == STATE_CALC)? tpu_B_index:cmd_payload_inputs_1[B_bits-1:0];
  wire [B_bits-1:0]tpu_B_index;
  wire [31:0]B_data_out;
  wire C_wr_en;
  wire [C_bits-1:0]C_index = (state == STATE_CALC)? tpu_C_index[C_bits-1:0]:C_index_read[C_bits-1:0];
  reg  [31:0]C_index_read;
  wire [15:0]tpu_C_index;
  wire [127:0]C_data_in;
  wire [127:0]C_data_out;
  wire tpu_busy;
  wire tpu_valid = cmd_valid && cmd_ready && cmd_payload_function_id[5:3] == func_go;
  reg  [1:0]c_read_offset;
  reg  [11:0]M_reg;
  global_buffer_bram #(.ADDR_BITS(A_bits))
  gbuff_A(
    .clk(clk),
    .rst_n(!reset),
    .ram_en(1'b1),
    .wr_en(A_wr_en),
    .index(A_index),
    .data_in(cmd_payload_inputs_0),
    .data_out(A_data_out)
  );
  global_buffer_bram #(.ADDR_BITS(B_bits))
  gbuff_B(
    .clk(clk),
    .rst_n(!reset),
    .ram_en(1'b1),
    .wr_en(B_wr_en),
    .index(B_index),
    .data_in(cmd_payload_inputs_0),
    .data_out(B_data_out)
  );
  global_buffer_bram #(.ADDR_BITS(C_bits), .DATA_BITS(128))
  gbuff_C(
    .clk(clk),
    .rst_n(!reset),
    .ram_en(1'b1),
    .wr_en(C_wr_en),
    .index(C_index),
    .data_in(C_data_in),
    .data_out(C_data_out)
  );
  TPU tpu(
    .clk(clk),
    .rst_n(!reset),
    .in_valid(tpu_valid),
    .K(cmd_payload_inputs_0[31:21]),
    .M(cmd_payload_inputs_0[20:9]),
    .N(cmd_payload_inputs_0[8:0]),
    .input_offset(cmd_payload_inputs_1),
    .busy(tpu_busy),
    .A_index(tpu_A_index),
    .A_data_out(A_data_out),
    .B_index(tpu_B_index),
    .B_data_out(B_data_out),
    .C_wr_en(C_wr_en),
    .C_index(tpu_C_index),
    .C_data_in(C_data_in)
  );

  localparam func_write_a  = 3'd0;
  localparam func_write_b  = 3'd1;
  localparam func_read_c   = 3'd2;
  localparam func_go       = 3'd3;
  localparam func_set_bias = 3'd4;
  localparam func_set_MBQM = 3'd5;

  localparam STATE_IDLE = 2'd0;
  localparam STATE_CALC = 2'd1;
  localparam STATE_READ = 2'd2;
  localparam STATE_DONE = 2'd3;

  reg [1:0]state;
  reg [1:0]state_next;
  always @(*) begin
    case (state)
      STATE_IDLE: state_next = 
      (cmd_valid && cmd_payload_function_id[5:3] == func_go)?     STATE_CALC:
      (cmd_valid && cmd_payload_function_id[5:3] == func_read_c)? STATE_READ:
                                                                  STATE_IDLE;
      STATE_CALC: state_next = tpu_busy? STATE_CALC:STATE_DONE;
      STATE_READ: state_next = (read_counter == 3'd1)? STATE_DONE:STATE_READ;
      STATE_DONE: state_next = (rsp_valid && rsp_ready)? STATE_IDLE:STATE_DONE;
      default: state_next = STATE_IDLE;
    endcase
  end
  always @(posedge clk) begin
    if(reset)
      state <= STATE_IDLE;
    else begin
      state <= state_next;
      if(state == STATE_IDLE)begin
        c_read_offset <= cmd_payload_inputs_1[1:0];
        C_index_read <= (cmd_payload_inputs_1 >> 2) * M_reg + cmd_payload_inputs_0;
        read_counter <= 3'b0;
        if(cmd_valid && cmd_payload_function_id[5:3] == func_set_bias)begin
          bias_reg <= cmd_payload_inputs_0;
          output_offset_reg <= cmd_payload_inputs_1;
        end else if(cmd_valid && cmd_payload_function_id[5:3] == func_set_MBQM)begin
          output_multiplier_reg <= cmd_payload_inputs_0;
          output_shift_reg <= ~cmd_payload_inputs_1 + 1'b1;
        end else if(cmd_valid && cmd_payload_function_id[5:3] == func_go)
          M_reg <= cmd_payload_inputs_0[20:9];
      end else if(state == STATE_READ)begin
        read_counter <= read_counter + 1'b1;
        rsp_outputs_reg <= rsp_outputs;
        product_unshift <= $signed(rsp_outputs_reg + bias_reg) * $signed(output_multiplier_reg);
      end
    end
  end
  assign cmd_ready = state == STATE_IDLE;
  assign rsp_valid = state == STATE_DONE || A_wr_en || B_wr_en
  || (cmd_valid && cmd_ready && cmd_payload_function_id[5:3] == func_set_bias)
  || (cmd_valid && cmd_ready && cmd_payload_function_id[5:3] == func_set_MBQM);
  assign rsp_payload_outputs_0 = ( final_product[31] && final_product < 32'hffffff80)? 32'h00000080:
                                 (!final_product[31] && final_product > 32'h0000007f)? 32'h0000007f:
                                 final_product;

  reg[31:0] bias_reg;
  reg[31:0] output_offset_reg;
  reg[31:0] output_multiplier_reg;
  reg[31:0] output_shift_reg;
  reg[2:0] read_counter;
  wire[31:0] rsp_outputs =
  (c_read_offset == 2'd0)? C_data_out[127:96]:
  (c_read_offset == 2'd1)? C_data_out[95:64]:
  (c_read_offset == 2'd2)? C_data_out[63:32]:
                           C_data_out[31:0];
  reg[31:0] rsp_outputs_reg;
  reg[63:0] product_unshift;
  wire signed[31:0] product_shifted = product_unshift[62:31];
  wire round_down = product_shifted[output_shift_reg - 1'b1] && (!product_shifted[31] || (product_shifted[31] && (|product_shifted[5:0] || (product_shifted[6] && !output_shift_reg[0]))));
  wire[31:0] product = (product_shifted >>> output_shift_reg) + $signed({2'b0, round_down});
  wire[31:0] final_product = product + output_offset_reg;

endmodule
