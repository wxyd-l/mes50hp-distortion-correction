`timescale 1ns/1ps
// =============================================================================
//  ud_coord_gen_dm_norm.v -- 团队 distortion_mapper 的 NORMALIZED_INPUT=1 封装
//
//  与 ud_coord_gen_dm.v 同接口（多两条 norm_x/norm_y 入口），区别只有一处:
//  实例化 distortion_mapper #(.NORMALIZED_INPUT(1))，于是核里
//  affine_x_q24 <= ext32(s0_norm_x)，a00/a01/a10/a11 那 4 个乘法变死代码。
//
//  【dm_mapper.v 一行不改】—— 这是硬约束，归一化只在外面这一层做。
//  核外的 Q16.16 -> Q8.24 收尾（to_q8 / ROUND_BIAS=128）与老封装逐字相同。
// =============================================================================
module ud_coord_gen_dm_norm #(
    parameter integer WIDTH  = 1280,
    parameter integer HEIGHT = 720,
    parameter integer K1_VAL = 0,
    parameter integer ROUND_BIAS = 128
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
    // 归一化坐标入口（Q8.24）：透视前端算好的 X/W、Y/W
    input  wire signed [31:0] norm_x,
    input  wire signed [31:0] norm_y,
    input  wire               norm_overflow,
    // 运行时可改参数（NORMALIZED_INPUT=1 时 a00/a01/a10/a11 已是死代码，接口保留）
    input  wire signed [31:0] cfg_a00, cfg_a01, cfg_a02,
    input  wire signed [31:0] cfg_a10, cfg_a11, cfg_a12,
    input  wire signed [31:0] cfg_k1,  cfg_k2,  cfg_p1,  cfg_p2,
    input  wire signed [31:0] cfg_fx,  cfg_fy,  cfg_cx,  cfg_cy
);

    wire               m_vld, m_ovf;
    wire [15:0]        m_u, m_v;
    wire signed [31:0] m_sx, m_sy;

    distortion_mapper #(.NORMALIZED_INPUT(1)) u_dm (
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
        .norm_x(norm_x), .norm_y(norm_y), .norm_overflow(norm_overflow)
    );

    // Q16.16 -> 整数 + 8 位权重；加半 LSB 四舍五入（团队核向下取整）
    function [18:0] to_q8;
        input signed [31:0] s;
        reg   [31:0] t;
        begin
            if (s < 32'sd0)               t = 32'd0;
            else if (s > 32'sd2147450880) t = 32'd2147483647;
            else                          t = s[31:0] + ROUND_BIAS;
            to_q8 = {t[27:16], t[15:8]};
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
