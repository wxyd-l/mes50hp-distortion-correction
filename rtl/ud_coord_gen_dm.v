// =============================================================================
//  ud_coord_gen_dm.v  --  团队 distortion_mapper.sv 的接口封装
//  与 ud_coord_gen.v 同接口，可直接替换。
//
//  【为什么参数内联而不用 include 文件】工程的 .pds 没有 incdir 设置，
//  include 文件在 PDS 里可能解析不到，白跑一轮综合。
//  14 个定点参数全部内联成 localparam；唯一需要切换的是 K1，做成 parameter。
//
//  定点约定（团队 numeric_contract.md）:
//    a00..a12 : Q4.28 逆仿射（已含 1/fx 与主点偏移）
//    k1,k2,p1,p2 : Q8.24
//    fx,fy,cx,cy : Q16.16
//    src_x,src_y : Q16.16 -> 整数 [31:16]，小数取 [23:16] 作 8 位权重
//
//  当前内联值对应: fx=750  cx=639.5  cy=359.5  k2=p1=p2=0
// =============================================================================
`timescale 1ns/1ps

module ud_coord_gen_dm #(
    parameter integer WIDTH  = 1280,
    parameter integer HEIGHT = 720,
    // Q8.24 的 k1: 0 = 直通验证;  -2248147 对应 k1 = -0.134
    parameter integer K1_VAL = 0,
    // 取整偏置: 最近邻用 32768(四舍五入), 双线性用 0(floor+真实小数)
    parameter integer ROUND_BIAS = 32768
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        din_vld,
    input  wire [11:0] din_u,
    input  wire [11:0] din_v,
    output wire        dout_vld,
    output wire [18:0] dout_ud_q8,
    output wire [18:0] dout_vd_q8,
    output wire [11:0] dout_uc,
    output wire [7:0]  dout_wx,
    output wire [11:0] dout_vr,
    output wire [7:0]  dout_wy,
    output wire [11:0] dout_u_pipe,
    // 运行时可改参数（由 ud_param_regs 驱动）
    input  wire signed [31:0] cfg_a00, cfg_a01, cfg_a02,
    input  wire signed [31:0] cfg_a10, cfg_a11, cfg_a12,
    input  wire signed [31:0] cfg_k1,  cfg_k2,  cfg_p1,  cfg_p2,
    input  wire signed [31:0] cfg_fx,  cfg_fy,  cfg_cx,  cfg_cy
);

    localparam signed [31:0] P_A00 = 357914;
    localparam signed [31:0] P_A01 = 0;
    localparam signed [31:0] P_A02 = -228885965;
    localparam signed [31:0] P_A10 = 0;
    localparam signed [31:0] P_A11 = 357914;
    localparam signed [31:0] P_A12 = -128670062;
    localparam signed [31:0] P_K1  = K1_VAL;
    localparam signed [31:0] P_K2  = 0;
    localparam signed [31:0] P_P1  = 0;
    localparam signed [31:0] P_P2  = 0;
    localparam signed [31:0] P_FX  = 49152000;
    localparam signed [31:0] P_FY  = 49152000;
    localparam signed [31:0] P_CX  = 41910272;
    localparam signed [31:0] P_CY  = 23560192;

    wire               m_vld, m_ovf;
    wire [15:0]        m_u, m_v;
    wire signed [31:0] m_sx, m_sy;

    distortion_mapper u_dm (
        .clk(clk), .rst_n(rst_n), .ce(1'b1),
        .in_valid(din_vld),
        .in_u({4'b0, din_u}),
        .in_v({4'b0, din_v}),
        .a00(cfg_a00), .a01(cfg_a01), .a02(cfg_a02),
        .a10(cfg_a10), .a11(cfg_a11), .a12(cfg_a12),
        .k1(cfg_k1), .k2(cfg_k2), .p1(cfg_p1), .p2(cfg_p2),
        .fx(cfg_fx), .fy(cfg_fy), .cx(cfg_cx), .cy(cfg_cy),
        .out_valid(m_vld), .out_overflow(m_ovf),
        .out_u(m_u), .out_v(m_v),
        .src_x(m_sx), .src_y(m_sy),
        .norm_x(32'sd0), .norm_y(32'sd0), .norm_overflow(1'b0)
    );

    // Q16.16 -> 整数 + 8 位权重；加半 LSB 四舍五入（团队核向下取整）
    // 溢出或负值一律钳位，钳位不会产生黑边
    function [18:0] to_q8;
        input signed [31:0] s;
        reg   [31:0] t;
        begin
            if (s < 32'sd0)               t = 32'd0;
            else if (s > 32'sd2147450880) t = 32'd2147483647;
            else                          t = s[31:0] + ROUND_BIAS;
            to_q8 = {t[27:16], t[15:8]};   // Q16.16: 整数 t[31:16], 小数 t[15:0] -> 权重取 t[15:8]
        end
    endfunction

    wire [18:0] uq = m_ovf ? 19'd0 : to_q8(m_sx);
    wire [18:0] vq = m_ovf ? 19'd0 : to_q8(m_sy);

    assign dout_vld    = m_vld;
    assign dout_ud_q8  = uq;
    assign dout_vd_q8  = vq;
    assign dout_uc     = uq[18:8];
    assign dout_wx     = uq[7:0];
    assign dout_vr     = vq[18:8];
    assign dout_wy     = vq[7:0];
    assign dout_u_pipe = m_u[11:0];

endmodule
