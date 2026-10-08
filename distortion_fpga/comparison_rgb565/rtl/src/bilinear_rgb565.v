`timescale 1ns/1ps
// Input is normalized RGB565: R[15:11], G[10:5], B[4:0].
// Do not interpolate the packed 16-bit word as a single number.
module bilinear_rgb565 #(parameter FRAC_BITS = 8)(
    input wire clk, rst_n, ce, in_valid,
    input wire [15:0] p00, p10, p01, p11,
    input wire [FRAC_BITS-1:0] fx, fy,
    output wire out_valid,
    output wire [15:0] out_pixel
);
    wire signed [5:0] r, b;
    wire signed [6:0] g;
    wire vg, vb;
    bilinear_signed #(.DATA_BITS(6),.FRAC_BITS(FRAC_BITS)) red (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(in_valid),
        .a00({1'b0,p00[15:11]}),.a10({1'b0,p10[15:11]}),
        .a01({1'b0,p01[15:11]}),.a11({1'b0,p11[15:11]}),
        .wx({1'b0,fx}),.wy({1'b0,fy}),.out_valid(out_valid),.out_value(r));
    bilinear_signed #(.DATA_BITS(7),.FRAC_BITS(FRAC_BITS)) green (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(in_valid),
        .a00({1'b0,p00[10:5]}),.a10({1'b0,p10[10:5]}),
        .a01({1'b0,p01[10:5]}),.a11({1'b0,p11[10:5]}),
        .wx({1'b0,fx}),.wy({1'b0,fy}),.out_valid(vg),.out_value(g));
    bilinear_signed #(.DATA_BITS(6),.FRAC_BITS(FRAC_BITS)) blue (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(in_valid),
        .a00({1'b0,p00[4:0]}),.a10({1'b0,p10[4:0]}),
        .a01({1'b0,p01[4:0]}),.a11({1'b0,p11[4:0]}),
        .wx({1'b0,fx}),.wy({1'b0,fy}),.out_valid(vb),.out_value(b));
    assign out_pixel = {r[4:0],g[5:0],b[4:0]};
endmodule
