`timescale 1ns/1ps
`default_nettype none
// Homography quotient followed by the same Brown-Conrady arithmetic pipeline.
// Initiation interval: 59 enabled cycles for a successful homogeneous token.
// ce freezes both modules, including the completed output token.
module projective_distortion_mapper #(
    parameter integer POSITIVE_DEPTH=0
)(
    input wire clk,rst_n,ce,in_valid,
    output wire in_ready,
    input wire [15:0] in_u,in_v,
    input wire signed [31:0] a00,a01,a02,a10,a11,a12,a20,a21,a22,
    input wire signed [31:0] k1,k2,p1,p2,fx,fy,cx,cy,
    output wire out_valid,out_overflow,
    output wire [15:0] out_u,out_v,
    output wire signed [31:0] src_x,src_y
);
    wire norm_valid,norm_error;
    wire [15:0] norm_u,norm_v;
    wire signed [31:0] norm_x,norm_y;
    homography_normalizer #(.POSITIVE_DEPTH(POSITIVE_DEPTH)) normalizer (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(in_valid),.in_ready(in_ready),
        .in_u(in_u),.in_v(in_v),
        .a00(a00),.a01(a01),.a02(a02),.a10(a10),.a11(a11),.a12(a12),
        .a20(a20),.a21(a21),.a22(a22),
        .out_valid(norm_valid),.out_overflow(norm_error),.out_u(norm_u),.out_v(norm_v),
        .norm_x(norm_x),.norm_y(norm_y)
    );
    distortion_mapper #(.NORMALIZED_INPUT(1)) brown_conrady (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(norm_valid),.in_u(norm_u),.in_v(norm_v),
        .a00(32'sd0),.a01(32'sd0),.a02(32'sd0),.a10(32'sd0),.a11(32'sd0),.a12(32'sd0),
        .k1(k1),.k2(k2),.p1(p1),.p2(p2),.fx(fx),.fy(fy),.cx(cx),.cy(cy),
        .norm_x(norm_x),.norm_y(norm_y),.norm_overflow(norm_error),
        .out_valid(out_valid),.out_overflow(out_overflow),.out_u(out_u),.out_v(out_v),
        .src_x(src_x),.src_y(src_y)
    );
endmodule
`default_nettype wire
