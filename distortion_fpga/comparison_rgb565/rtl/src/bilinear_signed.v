`timescale 1ns/1ps
// Three enabled-clock stages. Weights are unsigned [0,2**FRAC_BITS],
// inclusive, allowing exact grid endpoints. Round once, nearest/ties +infinity.
module bilinear_signed #(
    parameter DATA_BITS = 32,
    parameter FRAC_BITS = 8
)(
    input wire clk,
    input wire rst_n,
    input wire ce,
    input wire in_valid,
    input wire signed [DATA_BITS-1:0] a00, a10, a01, a11,
    input wire [FRAC_BITS:0] wx, wy,
    output reg out_valid,
    output reg signed [DATA_BITS-1:0] out_value
);
    localparam H_BITS = DATA_BITS + FRAC_BITS + 2;
    localparam ACC_BITS = DATA_BITS + 2*FRAC_BITS + 4;
    localparam [FRAC_BITS:0] ONE = (1 << FRAC_BITS);
    localparam signed [ACC_BITS-1:0] BIAS = {{(ACC_BITS-1){1'b0}},1'b1} << (2*FRAC_BITS-1);
    // synthesis translate_off
    initial begin
        if(FRAC_BITS<1 || FRAC_BITS>16 || DATA_BITS<2 || DATA_BITS>32)
            $fatal(1,"supported DATA_BITS=[2,32], FRAC_BITS=[1,16]");
    end
    // synthesis translate_on
    wire signed [FRAC_BITS+1:0] sx0 = $signed({1'b0, (ONE-wx)});
    wire signed [FRAC_BITS+1:0] sx1 = $signed({1'b0, wx});
    reg signed [H_BITS-1:0] top_sum, bottom_sum;
    reg [FRAC_BITS:0] wy_s1;
    wire signed [FRAC_BITS+1:0] sy0 = $signed({1'b0, (ONE-wy_s1)});
    wire signed [FRAC_BITS+1:0] sy1 = $signed({1'b0, wy_s1});
    reg signed [ACC_BITS-1:0] accumulator;
    reg v1, v2;
    always @(posedge clk) begin
        if (!rst_n) begin
            top_sum <= 0; bottom_sum <= 0; wy_s1 <= 0;
            accumulator <= 0; v1 <= 0; v2 <= 0;
            out_valid <= 0; out_value <= 0;
        end else if (ce) begin
            v1 <= in_valid;
            top_sum <= a00 * sx0 + a10 * sx1;
            bottom_sum <= a01 * sx0 + a11 * sx1;
            wy_s1 <= wy;
            v2 <= v1;
            accumulator <= top_sum * sy0 + bottom_sum * sy1;
            out_valid <= v2;
            out_value <= (accumulator + BIAS) >>> (2*FRAC_BITS);
        end
    end
endmodule
