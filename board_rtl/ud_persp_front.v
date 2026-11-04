`timescale 1ns/1ps
// =============================================================================
//  ud_persp_front.v -- M3b 透视前端（齐次归一化 = 除以 W）
//
//   (u,v) --> X = a00*u + a01*v + a02   (Q4.28, 主点已折进 a02)
//         --> Y = a10*u + a11*v + a12   (Q4.28)
//         --> W = w0  + h20*u + h21*v   (Q8.24)
//               r = floor(2^48 / W)     (26 级全流水 restoring 除法, x/y 共用)
//               norm_x = (X * r) >>> 28 (Q8.24)  -> distortion_mapper(NORMALIZED_INPUT=1)
//               norm_y = (Y * r) >>> 28 (Q8.24)
//
//  为什么这样定标最省事:
//    norm = (X/2^28) / (W/2^24) * 2^24 = X * 2^20 / W
//    而  (X * floor(2^48/W)) >>> 28   = X * 2^20 / W   —— 同一个式子，
//    所以倒数只算一次（x/y 共用一个 r），且 2^48 是常数，除数只剩 W 一个变数。
//
//  恒等 / 纯旋转时 h20=h21=0 -> W = 2^24 -> r = 2^24 -> norm = X >>> 4，
//  与老的非归一化通路 affine_x_q28 >>> 4 逐位相同：新管子不引入回归。
//
//  时延 LATF = 2(乘积/求和) + 26(除法) + 1(乘 r) = 29 拍。吞吐 1 pixel/cycle。
//  W 的合法范围 [0.46,1.55] 下 r 落在 [1.08e7, 3.65e7]，26 位装得下；
//  这里再夹到 [2^22+1, 2^25-1]，越界只在误配置时出现（norm_ovf 会报）。
// =============================================================================
module ud_persp_front #(
    parameter integer LATF = 29
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               ce,
    // 齐次分子（Q4.28）与分母（Q8.24），全部按绝对像素 u,v 展开（主点已折入常数项）
    input  wire signed [31:0] cfg_a00, cfg_a01, cfg_a02,
    input  wire signed [31:0] cfg_a10, cfg_a11, cfg_a12,
    input  wire signed [31:0] cfg_h20, cfg_h21, cfg_w0,
    input  wire               din_vld,
    input  wire [11:0]        din_u,
    input  wire [11:0]        din_v,
    output wire               dout_vld,
    output wire signed [31:0] norm_x,
    output wire signed [31:0] norm_y,
    output wire               norm_ovf
);

    localparam integer DS = 26;                       // 除法级数
    localparam signed [47:0] WMIN = 48'sd4194305;     // 2^22 + 1（保证 r 装得进 26 位）
    localparam signed [47:0] WMAX = 48'sd33554431;    // 2^25 - 1

    wire signed [12:0] uu = $signed({1'b0, din_u});
    wire signed [12:0] vv = $signed({1'b0, din_v});

    // ---------------- s0: 6 个乘积 ----------------
    reg signed [43:0] p_xu, p_xv, p_yu, p_yv, p_wu, p_wv;
    always @(posedge clk) begin
        if (ce) begin
            p_xu <= cfg_a00 * uu;
            p_xv <= cfg_a01 * vv;
            p_yu <= cfg_a10 * uu;
            p_yv <= cfg_a11 * vv;
            p_wu <= cfg_h20 * uu;
            p_wv <= cfg_h21 * vv;
        end
    end

    // ---------------- s1: X / Y / W ----------------
    reg signed [47:0] X_q28, Y_q28, W_q24;
    always @(posedge clk) begin
        if (ce) begin
            X_q28 <= p_xu + p_xv + cfg_a02;
            Y_q28 <= p_yu + p_yv + cfg_a12;
            W_q24 <= p_wu + p_wv + cfg_w0;
        end
    end

    wire signed [47:0] Wc = (W_q24 < WMIN) ? WMIN : ((W_q24 > WMAX) ? WMAX : W_q24);
    wire        [25:0] Dw = Wc[25:0];

    wire signed [31:0] X32 = X_q28[31:0];             // 合法配置下 |X| < 2^29，截不到
    wire signed [31:0] Y32 = Y_q28[31:0];

    // ---------------- 26 级全流水 restoring 除法 ----------------
    // Q = floor(2^48 / Dw): rem 初值 = 2^48 >> 26 = 2^22，
    // 每级 rem = rem<<1，若 >= Dw 则减 Dw 并置商位 1（商位由高到低生成）。
    reg  [25:0]        rm [0:DS-1];
    reg  [25:0]        dv [0:DS-1];
    reg  [25:0]        qt [0:DS-1];
    reg  signed [31:0] xd [0:DS-1];
    reg  signed [31:0] yd [0:DS-1];

    reg  [26:0] sh_t;
    reg  [25:0] dv_t;
    integer j;

    wire [26:0] sh0 = {26'd4194304, 1'b0};
    wire        ge0 = (sh0 >= {1'b0, Dw});

    always @(posedge clk) begin
        if (ce) begin
            rm[0] <= ge0 ? (sh0 - {1'b0, Dw}) : sh0[25:0];
            dv[0] <= Dw;
            qt[0] <= {25'd0, ge0};
            xd[0] <= X32;
            yd[0] <= Y32;
            for (j = 1; j < DS; j = j + 1) begin
                sh_t = {rm[j-1], 1'b0};
                dv_t = dv[j-1];
                if (sh_t >= {1'b0, dv_t}) begin
                    rm[j] <= sh_t - {1'b0, dv_t};
                    qt[j] <= {qt[j-1][24:0], 1'b1};
                end else begin
                    rm[j] <= sh_t[25:0];
                    qt[j] <= {qt[j-1][24:0], 1'b0};
                end
                dv[j] <= dv_t;
                xd[j] <= xd[j-1];
                yd[j] <= yd[j-1];
            end
        end
    end

    wire [25:0] rq = qt[DS-1];                        // r = floor(2^48/W)

    // ---------------- 最后一次乘 r ----------------
    reg signed [63:0] nx_prod, ny_prod;
    always @(posedge clk) begin
        if (ce) begin
            nx_prod <= $signed(xd[DS-1]) * $signed({1'b0, rq});
            ny_prod <= $signed(yd[DS-1]) * $signed({1'b0, rq});
        end
    end

    wire signed [63:0] nxs = nx_prod >>> 28;
    wire signed [63:0] nys = ny_prod >>> 28;

    assign norm_x   = nxs[31:0];
    assign norm_y   = nys[31:0];
    assign norm_ovf = (nxs[63:31] != {33{nxs[31]}}) || (nys[63:31] != {33{nys[31]}});

    // ---------------- valid 对齐 ----------------
    reg [LATF-1:0] vld_p;
    always @(posedge clk) begin
        if (!rst_n) vld_p <= {LATF{1'b0}};
        else if (ce) vld_p <= {vld_p[LATF-2:0], din_vld};
    end
    assign dout_vld = vld_p[LATF-1];

endmodule
