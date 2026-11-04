// =============================================================================
//  ud_tile_core_m3.v -- 读侧列条核心 M3a：源列窗口随行漂移 + 大行窗口
//
//  与 ud_tile_core_bil.v 的差别（M3a）:
//   1) 源列窗口不再"每条一个 win_x"，改成【每个源行一个基准 lo(r)】
//      行缓存按行存 256 列（SW=256），读地址 = cg_uc - lo(v1)，只在本行窗口内。
//      lo(r) = floor16( u_aff(r) + du_of(A2+B2, au2) - MARGIN )
//      其中 u_aff = (cfg_ux*x0 + cfg_uv*r + cfg_u0) >>> 16  （像素域仿射）
//      这一套已被 tools/m3a_window_check.mjs 在 0~45 度、k1=+-0.134/+-0.05/0 下验证 0 缺口。
//   2) RPB 24 -> 128（2 的幂，取模免费），行窗口够任意角度用。
//   3) SW 192 -> 256：一行需要的最坏跨度 ~152 + 漂移余量，256 留足。
//
//  不变的部分: 行缓存奇偶双 bank、逐拍时序、水平/垂直插值、状态机。
// =============================================================================
`timescale 1ns/1ps

module ud_tile_core_m3 #(
    parameter integer TW     = 160,
    parameter integer SW     = 256,    // 每个源行的窗口宽度（16 的倍数）
    parameter integer HEIGHT = 720,
    parameter integer RPB    = 128,    // 行窗口（2 的幂）
    parameter integer MARGIN = 56,     // 源列窗口左侧余量
    // 像素域仿射（Q16.16）: 源列 = (P_UX*tile_x0 + P_UV*v_out + P_U0) >>> 16
    parameter integer P_UX = 65536, P_UV = 0, P_U0 = 0,
    // 逆映射（Q16.16）: v_out = CY + (r - CY)*P_IV   （P_IV = 1/(a11*fx)）
    parameter integer P_IV = 65536,
    // 竖向像素域仿射（Q16.16）: v_aff = (P_VX*tc + P_VV*row_v + P_V0) >>> 16
    parameter integer P_VX = 0, P_VV = 65536, P_V0 = 0,
    // 团队核 14 个参数（默认 = 恒等仿射, 与 M2 一致）
    parameter integer P_A00 = 357914, P_A01 = 0, P_A02 = -228885965,
    parameter integer P_A10 = 0, P_A11 = 357914, P_A12 = -128670062,
    parameter integer P_K1 = -2248147, P_K2 = 0, P_P1 = 0, P_P2 = 0,
    parameter integer P_FX = 49152000, P_FY = 49152000,
    parameter integer P_CX = 41910272, P_CY = 23560192,
    parameter integer LEAD   = 2,
    parameter integer LAG    = 20,
    parameter integer XEXT   = 24,
    parameter integer K1CFG  = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [11:0] row_v,
    input  wire [11:0] tile_x0,
    output reg         fd_req,
    output reg  [11:0] fd_row,
    output reg  [11:0] fd_x0,
    input  wire        fd_ack,
    input  wire [31:0] fd_data,
    input  wire        fd_data_vld,
    // 像素域仿射（Q16.16）: 源列 = cfg_ux*tile_x0 + cfg_uv*row_v + cfg_u0
    input  wire signed [31:0] cfg_ux,
    input  wire signed [31:0] cfg_uv,
    input  wire signed [31:0] cfg_u0,
    output reg         de_o,
    output reg  [15:0] data_o,
    output reg         row_done
);

    localparam integer CX2V = 1279;             // 2*cx
    localparam integer FX2V = 750*750;
    localparam integer K1P  = (P_K1 >= 0) ? ((P_K1 + FX2V/2)/FX2V)
                                          : -(((-P_K1) + FX2V/2)/FX2V);
    localparam integer CY2V = 719;              // 2*cy
    localparam integer HALF = RPB/2;
    localparam integer WW   = SW/2;
    localparam integer VWD  = SW + 2;
    localparam integer RLEN = TW + XEXT + 8;
    localparam integer LATCG= 12;
    localparam [11:0]  XMAX12 = 1280 - SW;
    localparam [7:0]   SWM8   = SW - 1;

    // 状态机寄存器（base_t 流水要用到 sv_x0/sv_row，提前声明）
    reg [11:0] base, vtop, need_top, sv_row, sv_x0;
    reg        ld_vtop;
    reg [11:0] vtop_ld;

    // ---------------- 行窗口基准：竖向也用像素域仿射（两级流水） ----------------
    // 组合版是 row_v -> 乘法 -> APM -> vc_s -> 比较 -> ld_vtop 的长链，
    // 实测 WNS -0.285 ns / 10 端点违例。这里在第 1 级后切一刀，
    // 代价是 S_IDLE 多等 3 拍（tile 内取数要 128 拍，可忽略）。
    wire signed [47:0] vaff_q16 = $signed(P_VX) * $signed({20'd0, sv_x0}) + $signed(P_VX) * (TW/2)
                                + $signed(P_VV) * $signed({20'd0, sv_row}) + $signed(P_V0);
    wire signed [47:0] vaff_s   = vaff_q16 >>> 16;
    wire signed [23:0] vaff_w   = (vaff_s < 0) ? 24'sd0 : vaff_s[23:0];
    wire        [11:0] v_aff    = (vaff_w > HEIGHT-1) ? (HEIGHT-1) : vaff_w[11:0];
    wire signed [13:0] b2c  = {2'b0, v_aff, 1'b0} - CY2V[13:0];
    wire signed [13:0] au2c = ({1'b0, sv_x0, 1'b0} + TW) - CX2V[13:0];
    wire signed [27:0] A2c  = (au2c * au2c) >>> 2;
    wire signed [27:0] B2c  = (b2c  * b2c ) >>> 2;
    wire signed [28:0] R2c  = A2c + B2c;
    wire signed [47:0] R2w  = {{19{R2c[28]}}, R2c};
    wire signed [47:0] b2w  = {{34{b2c[13]}}, b2c};
    wire signed [47:0] dvc_c= (K1P * R2w * b2w) >>> 25;

    reg signed [23:0] dvc_r, b2_r;
    always @(posedge clk) begin
        if (!rst_n) begin dvc_r <= 24'sd0; b2_r <= 24'sd0; end
        else begin dvc_r <= dvc_c[23:0]; b2_r <= {{10{b2c[13]}}, b2c}; end
    end

    wire signed [23:0] vc_h = b2_r + (dvc_r <<< 1) + CY2V[23:0];
    wire signed [23:0] vc_s = vc_h >>> 1;
    wire signed [23:0] bsel = vc_s - MARGIN - LEAD;
    wire        [11:0] base_t= (bsel < 0)          ? 12'd0 :
                               (bsel > HEIGHT-RPB) ? (HEIGHT-RPB) :
                                                     bsel[11:0];

    // ---------------- 每行源列窗口基准 lo(r) ----------------
    reg  signed [47:0] ux0_q16;                 // cfg_ux * tile_x0, 每条算一次
    wire signed [47:0] uaff_q16 = ux0_q16 + cfg_uv * $signed({20'd0, row_v}) + cfg_u0;

    // 逐行求 lo(q)：3 级流水，取数引擎每行有 128 拍，完全够。
    // 组合版会把 apm -> wbase 写数据串成一条超长路径（实测 WNS -2.75ns），所以必须切开。
    reg  [11:0] pen_row;
    reg  [1:0]  f_pre;
    reg signed [23:0] p_u;
    reg signed [13:0] p_au2;
    reg signed [27:0] p_r2;
    reg signed [47:0] p_du;

    // 逆映射: 源行 r 对应的输出行 v_out（Q16.16 先算再取整）
    wire signed [47:0] pen2 = $signed({20'd0, pen_row}) * 48'sd2 - 48'sd719;
    wire signed [47:0] vout_q16 = (pen2 * $signed(P_IV)) >>> 16;
    wire signed [47:0] vout_w = (vout_q16 + 48'sd719) >>> 1;
    wire        [11:0] v_out    = (vout_w < 0) ? 12'd0 : (vout_w > HEIGHT-1 ? HEIGHT-1 : vout_w[11:0]);
    wire signed [47:0] uq_raw = (ux0_q16 + $signed(cfg_uv) * $signed({20'd0, v_out}) + $signed(cfg_u0)) >>> 16;
    wire signed [47:0] uq_w   = (uq_raw < 0) ? 48'sd0 : uq_raw;
    wire signed [13:0] au2_w  = ({1'b0, uq_w[11:0], 1'b0}) - CX2V[13:0];
    wire signed [13:0] b2_w   = {2'b0, pen_row, 1'b0} - CY2V[13:0];
    wire signed [27:0] a2_w   = (au2_w * au2_w) >>> 2;
    wire signed [27:0] bb2_w  = (b2_w  * b2_w ) >>> 2;
    wire signed [47:0] du_w   = ((K1P * (a2_w + bb2_w)) * au2_w) >>> 25;
    wire signed [47:0] lo_w   = $signed({{24{p_u[23]}}, p_u[23:0]}) + p_du - MARGIN;
    wire signed [47:0] lo_q   = (lo_w < 0) ? 48'sd0 : ((lo_w >>> 4) <<< 4);
    wire        [11:0] lo_cl  = (lo_q > XMAX12) ? XMAX12 : lo_q[11:0];

    // ---------------- 行缓存 ----------------
    // 按【行奇偶 × 列奇偶】拆 4 块：总位宽与原来的 2×32bit 相同，不额外占存储。
    // 拆列奇偶是为了【单拍拿到同一行的相邻两列】—— 双线性必须先水平后竖向，
    // 而每个 token 的 (v1, wy) 只对它自己那一列成立，不能借用邻居 token 的竖向样本。
    reg [15:0] memEE [0:HALF*WW-1];             // even 行, even 列
    reg [15:0] memEO [0:HALF*WW-1];             // even 行, odd  列
    reg [15:0] memOE [0:HALF*WW-1];             // odd  行, even 列
    reg [15:0] memOO [0:HALF*WW-1];             // odd  行, odd  列
    reg [11:0] wbase [0:RPB-1];                 // 每个源行的窗口基准

    localparam S_IDLE = 0, S_PRE = 1, S_FILL = 2, S_SWEEP = 3;
    reg [2:0]  st;
    reg [1:0]  pre_cnt;

    // ---------------- 取数引擎 ----------------
    reg        f_busy, f_wait;
    reg [11:0] f_row;
    reg [7:0]  f_col;
    wire [16:0] fslot = ((f_row[6:0]) >> 1) * WW;   // RPB=128 -> 取模免费

    always @(posedge clk) begin
        if (!rst_n) begin
            f_busy<=1'b0; f_wait<=1'b0; fd_req<=1'b0; f_pre<=2'd0;
            f_row<=12'd0; f_col<=8'd0; vtop<=12'd0;
            p_u<=24'sd0; p_au2<=14'sd0; p_r2<=28'sd0; p_du<=48'sd0; pen_row<=12'd0;
        end else if (ld_vtop) begin
            vtop <= vtop_ld; f_busy <= 1'b0; f_wait <= 1'b0; fd_req <= 1'b0; f_pre<=2'd0;
        end else if (!f_busy) begin
            fd_req <= 1'b0;
            case (f_pre)
            2'd0: if (vtop < need_top) begin pen_row <= vtop; f_pre <= 2'd1; end
            2'd1: begin p_u <= uq_w[23:0]; p_au2 <= au2_w; p_r2 <= a2_w + bb2_w; f_pre <= 2'd2; end
            2'd2: begin p_du <= ((K1P * p_r2) * p_au2) >>> 25; f_pre <= 2'd3; end
            default: begin
                wbase[vtop[6:0]] <= lo_cl;
                fd_x0 <= lo_cl;
                f_busy<=1'b1; f_wait<=1'b1; f_row<=vtop; fd_row<=vtop; fd_req<=1'b1; f_col<=8'd0;
                f_pre <= 2'd0;
            end
            endcase
        end else begin
            if (f_wait) begin
                if (fd_ack) begin fd_req<=1'b0; f_wait<=1'b0; end
            end else if (fd_data_vld) begin
                // 一拍两像素：低半字 = 偶列, 高半字 = 奇列
                if (f_row[0]) begin
                    memOE[fslot + f_col] <= fd_data[15:0];
                    memOO[fslot + f_col] <= fd_data[31:16];
                end else begin
                    memEE[fslot + f_col] <= fd_data[15:0];
                    memEO[fslot + f_col] <= fd_data[31:16];
                end
                f_col <= f_col + 1'b1;
                if (f_col == WW-1) begin f_busy<=1'b0; vtop <= f_row + 1'b1; end
            end
        end
    end

    // ---------------- 坐标发生器 ----------------
    wire        cg_vld;
    wire [18:0] cg_ud, cg_vd;
    wire [11:0] cg_uc, cg_vr;
    wire [7:0]  cg_wx, cg_wy;
    reg  [11:0] n;
    reg         sweep_on;
    wire [12:0] gu = {1'b0, sv_x0} + {1'b0, n};

    ud_coord_gen_dm #(.WIDTH(TW), .HEIGHT(HEIGHT), .K1_VAL(P_K1), .ROUND_BIAS(128)) u_cg (
        .clk(clk), .rst_n(rst_n),
        .din_vld(sweep_on && (n < TW + XEXT)), .din_u(gu[11:0]), .din_v(sv_row),
        .dout_vld(cg_vld), .dout_ud_q8(cg_ud), .dout_vd_q8(cg_vd),
        .dout_uc(cg_uc), .dout_wx(cg_wx), .dout_vr(cg_vr), .dout_wy(cg_wy),
        .dout_u_pipe(),
        .cfg_a00(P_A00), .cfg_a01(P_A01), .cfg_a02(P_A02),
        .cfg_a10(P_A10), .cfg_a11(P_A11), .cfg_a12(P_A12),
        .cfg_k1(P_K1), .cfg_k2(P_K2), .cfg_p1(P_P1), .cfg_p2(P_P2),
        .cfg_fx(P_FX), .cfg_fy(P_FY), .cfg_cx(P_CX), .cfg_cy(P_CY)
    );

    wire [11:0] tok_col = (n >= LATCG) ? (n[11:0] - LATCG[11:0]) : 12'd0;

    // ---------------- 读地址：本行窗口基准 ----------------
    wire [11:0] v1 = (cg_vr > HEIGHT-1) ? (HEIGHT-1) : cg_vr;
    wire [11:0] v2 = (v1 >= HEIGHT-1)  ? (HEIGHT-1) : (v1 + 12'd1);

    // 两个 bank 读的是不同源行, 各自用自己的窗口基准（相邻行基准可差 16 列）
    wire [11:0] e12  = v1[0] ? v2 : v1;
    wire [11:0] o12  = v1[0] ? (v1 - 12'd1) : v1;
    wire [11:0] rowE = e12;                       // memE 槽里真正那一行
    wire [11:0] rowO = v1[0] ? v1 : v2;           // memO 槽里真正那一行
    wire [11:0] wbE = wbase[rowE[6:0]];
    wire [11:0] wbO = wbase[rowO[6:0]];

    // 需要【同一行的相邻两列】：col = uc 与 uc+1，各自按本行窗口钳位
    wire [12:0] uc_p1 = {1'b0, cg_uc} + 13'd1;
    wire signed [13:0] lE0 = $signed({1'b0, cg_uc}) - $signed({1'b0, wbE});
    wire signed [13:0] lE1 = $signed(uc_p1)         - $signed({1'b0, wbE});
    wire signed [13:0] lO0 = $signed({1'b0, cg_uc}) - $signed({1'b0, wbO});
    wire signed [13:0] lO1 = $signed(uc_p1)         - $signed({1'b0, wbO});
    wire [7:0] cE0 = (lE0 < 0) ? 8'd0 : (lE0 > SWM8) ? SWM8 : lE0[7:0];
    wire [7:0] cE1 = (lE1 < 0) ? 8'd0 : (lE1 > SWM8) ? SWM8 : lE1[7:0];
    wire [7:0] cO0 = (lO0 < 0) ? 8'd0 : (lO0 > SWM8) ? SWM8 : lO0[7:0];
    wire [7:0] cO1 = (lO1 < 0) ? 8'd0 : (lO1 > SWM8) ? SWM8 : lO1[7:0];

    wire        rval = sweep_on && cg_vld && (v1 >= base) && (v1 < base + RPB);

    wire [11:0] slE = (e12 >> 1) & (HALF-1);
    wire [11:0] slO = (o12 >> 1) & (HALF-1);
    // 偶列数组取"那根偶列"，奇列数组取"那根奇列"
    wire [16:0] aeE = slE * WW + (cE0[0] ? cE1[7:1] : cE0[7:1]);
    wire [16:0] aoE = slE * WW + (cE0[0] ? cE0[7:1] : cE1[7:1]);
    wire [16:0] aeO = slO * WW + (cO0[0] ? cO1[7:1] : cO0[7:1]);
    wire [16:0] aoO = slO * WW + (cO0[0] ? cO0[7:1] : cO1[7:1]);

    reg [15:0] qEE, qEO, qOE, qOO;
    reg [11:0] v1_d, v2_d;
    reg [7:0]  cE0_d, cE1_d, cO0_d, cO1_d;
    reg        rval_d;
    reg [7:0]  wy_d, wx_d;
    always @(posedge clk) begin
        qEE    <= memEE[aeE];
        qEO    <= memEO[aoE];
        qOE    <= memOE[aeO];
        qOO    <= memOO[aoO];
        v1_d   <= v1;
        v2_d   <= v2;
        cE0_d  <= cE0;  cE1_d <= cE1;
        cO0_d  <= cO0;  cO1_d <= cO1;
        rval_d <= rval;
        wy_d   <= cg_wy;
        wx_d   <= cg_wx;
    end

    function [5:0] mixc;
        input [5:0] x0, x1;
        input [7:0] w;
        reg signed [17:0] d, acc;
        begin
            d   = $signed({1'b0, x1}) - $signed({1'b0, x0});
            acc = $signed({1'b0, x0}) * 18'sd256 + d * $signed({1'b0, w});
            mixc = acc[13:8];
        end
    endfunction

    // 逐通道混合（水平、竖向共用）
    function [15:0] mixp;
        input [15:0] a, b;
        input [7:0]  w;
        reg [5:0] rr, gg, bb;
        begin
            rr = mixc(a[15:11], b[15:11], w);
            gg = mixc(a[10:5],  b[10:5],  w);
            bb = mixc(a[4:0],   b[4:0],   w);
            mixp = {rr[4:0], gg, bb[4:0]};
        end
    endfunction

    // 同一行的相邻两列（偶列走 qEE/qOE，奇列走 qEO/qOO）
    wire [15:0] pE0 = cE0_d[0] ? qEO : qEE;
    wire [15:0] pE1 = (cE0_d == cE1_d) ? pE0 : (cE0_d[0] ? qEE : qEO);
    wire [15:0] pO0 = cO0_d[0] ? qOO : qOE;
    wire [15:0] pO1 = (cO0_d == cO1_d) ? pO0 : (cO0_d[0] ? qOE : qOO);

    // 先水平：每根列在【它自己那一行】上取相邻两列插值
    wire [15:0] hE = mixp(pE0, pE1, wx_d);        // rowE 那一行
    wire [15:0] hO = mixp(pO0, pO1, wx_d);        // rowO 那一行

    // 水平混合结果打一拍再竖向：横向 mixp + 竖向 mixp 挤在一拍里会超时
    // （实测 WNS -1.262 ns / 18 端点违例；切开后回到正裕量）。LAG=20 对 LATCG=12 仍有余量。
    reg [15:0] hE_r, hO_r;
    reg [11:0] v1_dd, v2_dd;
    reg [7:0]  wy_dd;
    reg        rval_dd;
    always @(posedge clk) begin
        if (!rst_n) begin
            hE_r<=16'd0; hO_r<=16'd0; v1_dd<=12'd0; v2_dd<=12'd0;
            wy_dd<=8'd0; rval_dd<=1'b0;
        end else begin
            hE_r <= hE;  hO_r <= hO;
            v1_dd <= v1_d; v2_dd <= v2_d;
            wy_dd <= wy_d; rval_dd <= rval_d;
        end
    end

    wire [15:0] ra16 = v1_dd[0] ? hO_r : hE_r;     // v1 那一行
    wire [15:0] rb16 = v1_dd[0] ? hE_r : hO_r;     // v2 那一行
    // v2 在底边会被夹成 HEIGHT-1 = v1：此时 memEE 槽里装的是 v1-1（奇偶 bank 退化），
    // 直接退回 ra16（双线性在边界退化为单行采样）。
    wire        rb_ok = (v2_dd != v1_dd) && (v2_dd >= base) && (v2_dd < base + RPB);
    wire [15:0] rb16e = rb_ok ? rb16 : ra16;

    // 再竖向 -> 最终像素
    wire [15:0] vval = mixp(ra16, rb16e, wy_dd);

    // 列条缓冲按【绝对源列 & (SW-1)】寻址：一个输出行内源列跨度 < SW，不会撞名。
    // 这样水平相邻列 u、u+1 总能落到相邻槽位，与每行各自的窗口基准无关。
    // ---------------- 输出 ----------------
    // 每个 token 已经算出完整像素，token 顺序就是输出顺序。
    // 缓冲必须按【token 序号】寻址（写 n-LATCG、读 n-LAG，相差 8，不会撞）；
    // 绝不能按【源列】寻址 —— 旋转下相邻 token 的 uc 会重复，后写的会把先写的覆盖掉。
    reg [15:0] vbuf [0:SW-1];
    reg [7:0]  col_d, col_dd;
    always @(posedge clk) begin
        // 写索引必须和数据同拍：vval 比原设计晚 1 拍，col_d 也要跟着再延 1 拍
        if (rval_dd) vbuf[col_dd] <= vval; // 行窗口未命中时保持（与旧版"陈旧值"语义一致）
        col_d  <= tok_col;
        col_dd <= col_d;
    end

    wire        h_en  = sweep_on && (n >= LAG) && (n < TW + LAG);
    wire [11:0] u_out = (n >= LAG) ? (n - LAG[11:0]) : 12'd0;
    wire [15:0] buf_q = vbuf[u_out[7:0]];

    reg [15:0] s1, s2;
    always @(posedge clk) begin
        if (!rst_n) begin s1<=16'd0; s2<=16'd0; end
        else begin s1 <= buf_q; s2 <= s1; end
    end

    reg de_d1, de_d2;
    always @(posedge clk) begin
        if (!rst_n) begin de_o<=1'b0; de_d1<=1'b0; de_d2<=1'b0; data_o<=16'd0; end
        else begin
            de_d1  <= h_en;
            de_d2  <= de_d1;
            data_o <= s2;
            de_o   <= de_d2;
        end
    end

    // ---------------- 主状态机 ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st<=S_IDLE; row_done<=1'b0; base<=0; need_top<=0; pre_cnt<=2'd0;
            sweep_on<=1'b0; n<=12'd0; sv_row<=0; sv_x0<=0;
            ld_vtop<=1'b0; vtop_ld<=12'd0; ux0_q16<=48'sd0;
        end else begin
            row_done <= 1'b0;
            case (st)
            S_IDLE: begin
                sweep_on <= 1'b0;
                if (start) begin
                    sv_row <= row_v; sv_x0 <= tile_x0;
                    ux0_q16 <= cfg_ux * $signed({20'd0, tile_x0});
                    pre_cnt <= 2'd2;
                    st <= S_PRE;
                end
                else if (ld_vtop) ld_vtop <= 1'b0;
            end
            // 等 base_t 的两级流水走完再提交（base_t 现在来自 sv_row/sv_x0）
            S_PRE: begin
                if (pre_cnt != 2'd0) pre_cnt <= pre_cnt - 1'b1;
                else begin
                    base     <= base_t;
                    need_top <= base_t + RPB;
                    if (base_t < base || base_t > base + RPB) begin
                        ld_vtop <= 1'b1;  vtop_ld <= base_t;
                    end
                    st <= S_FILL;
                end
            end
            S_FILL: begin
                if (ld_vtop) ld_vtop <= 1'b0;
                else if (vtop >= need_top && !f_busy) begin
                    n <= 12'd0; sweep_on <= 1'b1; st <= S_SWEEP;
                end
            end
            S_SWEEP: begin
                n <= n + 1'b1;
                if (vtop == need_top && !f_busy && (base > 0) &&
                    (base < HEIGHT - RPB) && (vtop < HEIGHT))
                    need_top <= need_top + 1'b1;
                if (n == RLEN-1) begin
                    sweep_on <= 1'b0; row_done <= 1'b1; st <= S_IDLE;
                end
            end
            endcase
        end
    end

endmodule
