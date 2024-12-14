// Copyright 2024 Wei-Ming Huang

module TPU(
    clk,
    rst_n,

    in_valid,
    K,
    M,
    N,
    input_offset,
    busy,

    A_wr_en,
    A_index,
    A_data_in,
    A_data_out,

    B_wr_en,
    B_index,
    B_data_in,
    B_data_out,

    C_wr_en,
    C_index,
    C_data_in,
    C_data_out
);

input clk;
input rst_n;
input            in_valid;
input [10:0]     K;
input [11:0]     M;
input [8:0]      N;
input [31:0]     input_offset;
output  reg      busy = 0;

output           A_wr_en;
output [18:0]    A_index;
output [31:0]    A_data_in;
input  [31:0]    A_data_out;

output           B_wr_en;
output [17:0]    B_index;
output [31:0]    B_data_in;
input  [31:0]    B_data_out;

output           C_wr_en;
output [15:0]    C_index;
output [127:0]   C_data_in;
input  [127:0]   C_data_out;

localparam A_bits = 15;
localparam B_bits = 15;
integer      i;
reg [10:0]   K_reg;
reg [11:0]   M_reg;
reg [8:0]    N_reg;
reg          C_wr_en_reg, done;
reg  [A_bits-1:0]  A_index_reg;
reg  [B_bits-1:0]  B_index_reg;
reg  [15:0]  C_index_reg;
reg  [127:0] C_data_in_reg;
reg  [15:0]  counter;
reg  signed[31:0]  PE[15:0], input_offset_reg;
reg  [31:0]A_data_out_reg, B_data_out_reg;
reg  signed[15:0]  prod[15:0];
reg  [A_bits-1:0]   A_Block_index, B_Block_index;
wire [A_bits-1:0]   A_Block_num = (M_reg[1:0] == 2'b0)? (M_reg >> 2) - 1 : M_reg >> 2;
wire [B_bits-1:0]   B_Block_num = (N_reg[1:0] == 2'b0)? (N_reg >> 2) - 1 : N_reg >> 2;

assign C_wr_en = C_wr_en_reg;
assign A_index = A_index_reg;
assign B_index = B_index_reg;
assign C_index = C_index_reg;
assign C_data_in = C_data_in_reg;

reg state = 0;
reg state_next;
localparam STATE_IDLE = 1'b0;
localparam STATE_CALC = 1'b1;

always @(posedge clk) begin
    A_data_out_reg <= A_data_out;
    B_data_out_reg <= B_data_out;
end

always @(posedge clk) begin
    prod[ 0] <= ($signed(A_data_out_reg[31:24]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[31:24]);
    prod[ 1] <= ($signed(A_data_out_reg[31:24]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[23:16]);
    prod[ 2] <= ($signed(A_data_out_reg[31:24]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[15: 8]);
    prod[ 3] <= ($signed(A_data_out_reg[31:24]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[ 7: 0]);
    prod[ 4] <= ($signed(A_data_out_reg[23:16]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[31:24]);
    prod[ 5] <= ($signed(A_data_out_reg[23:16]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[23:16]);
    prod[ 6] <= ($signed(A_data_out_reg[23:16]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[15: 8]);
    prod[ 7] <= ($signed(A_data_out_reg[23:16]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[ 7: 0]);
    prod[ 8] <= ($signed(A_data_out_reg[15: 8]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[31:24]);
    prod[ 9] <= ($signed(A_data_out_reg[15: 8]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[23:16]);
    prod[10] <= ($signed(A_data_out_reg[15: 8]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[15: 8]);
    prod[11] <= ($signed(A_data_out_reg[15: 8]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[ 7: 0]);
    prod[12] <= ($signed(A_data_out_reg[ 7: 0]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[31:24]);
    prod[13] <= ($signed(A_data_out_reg[ 7: 0]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[23:16]);
    prod[14] <= ($signed(A_data_out_reg[ 7: 0]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[15: 8]);
    prod[15] <= ($signed(A_data_out_reg[ 7: 0]) + $signed(input_offset_reg[8:0])) * $signed(B_data_out_reg[ 7: 0]);
end
always @(*) begin
    case (state)
        STATE_IDLE: state_next = in_valid? STATE_CALC:STATE_IDLE;
        STATE_CALC: state_next = done? STATE_IDLE:STATE_CALC;
        default: state_next = STATE_IDLE;
    endcase
end
always @(posedge clk) begin
    state <= state_next;
    if(!rst_n)begin
        state <= STATE_IDLE;
    end else if(state == STATE_IDLE)begin
        C_wr_en_reg <= 1'b0;
        K_reg <= K;
        M_reg <= M;
        N_reg <= N;
        input_offset_reg <= input_offset;
        for (i = 0; i < 32'd32; i = i + 1)
            PE[i] <= 32'b0;
        A_Block_index <= 15'b0;
        B_Block_index <= 15'b0;
        counter <= 16'b0;
        done <= 1'b0;
        if(in_valid)
            busy <= 1;
    end else if(state == STATE_CALC)begin
        counter <= counter + 1;
        C_wr_en_reg <= 0;
        if(counter < K_reg)begin
        A_index_reg <= counter + A_Block_index * K_reg;
        B_index_reg <= counter + B_Block_index * K_reg;
        end
        if(counter > 2'd2 && counter <= K_reg + 2'd2)begin
            PE[ 0] <= PE[ 0] + prod[ 0];
            PE[ 1] <= PE[ 1] + prod[ 1];
            PE[ 2] <= PE[ 2] + prod[ 2];
            PE[ 3] <= PE[ 3] + prod[ 3];
            PE[ 4] <= PE[ 4] + prod[ 4];
            PE[ 5] <= PE[ 5] + prod[ 5];
            PE[ 6] <= PE[ 6] + prod[ 6];
            PE[ 7] <= PE[ 7] + prod[ 7];
            PE[ 8] <= PE[ 8] + prod[ 8];
            PE[ 9] <= PE[ 9] + prod[ 9];
            PE[10] <= PE[10] + prod[10];
            PE[11] <= PE[11] + prod[11];
            PE[12] <= PE[12] + prod[12];
            PE[13] <= PE[13] + prod[13];
            PE[14] <= PE[14] + prod[14];
            PE[15] <= PE[15] + prod[15];
        end else if(counter >= K_reg + 3'd3 && counter <= K_reg + 3'd6)begin
            C_wr_en_reg <= 1;
            C_index_reg <= counter - K_reg - 3'd3 + A_Block_index * 3'd4 + B_Block_index * M_reg;
            C_data_in_reg <= (counter - K_reg == 16'd3)? {PE[ 0], PE[ 1], PE[ 2], PE[ 3]}
                        :  (counter - K_reg == 16'd4)? {PE[ 4], PE[ 5], PE[ 6], PE[ 7]}
                        :  (counter - K_reg == 16'd5)? {PE[ 8], PE[ 9], PE[10], PE[11]}
                        :  (counter - K_reg == 16'd6)? {PE[12], PE[13], PE[14], PE[15]}
                        :  128'bx;
        end else if(counter == K_reg + 4'd7 || (counter == 16'd7 && K_reg == 8'd2))begin
            if(A_Block_index == A_Block_num && B_Block_index == B_Block_num)begin
                done <= 1;
                busy <= 0;
            end else if(A_Block_index == A_Block_num)begin
                A_Block_index <= 7'b0;
                B_Block_index <= B_Block_index + 1;
            end else
                A_Block_index <= A_Block_index + 1;
            counter <= 16'b0;
            for (i = 0; i < 32'd32; i = i + 1)
                PE[i] <= 32'b0;
        end
    end
end
endmodule