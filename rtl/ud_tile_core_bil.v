// =============================================================================
//  ud_tile_core_bil.v -- 读侧列条核心：16 位 + 双线性 + 源列窗口对齐
//
//  【为什么需要源列窗口 xs】逆映射下"输出列 u"落到"源列 src_x(u,v)"，
//  两者不在同一个坐标系里。桶形 k1<0 时 src_x 整体向中心收缩：第 0 条
//  (u∈[0,160)) 实际要读的源列是 [62,201]，而旧版按 tile_x0=[0,160) 取数 ->
//  超出部分被钳死，几何是错的（旧 TB 只在 k1=0 时比数值，所以没发现）。
//  这里用与行窗口同一个简化径向式在线算出这条的源列窗口起点：
//      src_x(u0,v) = u0 + K1P*R2*au2 >>> 25     (au2 = 2*(u0-cx), R2 = r2_px)
//  取 x0 与 x0+TW 两个边缘、B2∈{0,B2MAX} 两个极值 -> xs = 16 对齐下取整。
//  实测 8 条最坏需要 176 列，SW=192 留 16 列余量。
//
//  【行缓存：奇偶双 bank】
//    vr 与 vr+1 必须同拍来自不同阵列，且不能"条件二选一读两个数组"
//    （会推成分布式 RAM）。按奇偶选【槽号】不选【阵列】：
//       v1 偶: memE 读 v1/2, memO 读 v1/2
//       v1 奇: memE 读 (v1+1)/2, memO 读 (v1-1)/2
//    两个阵列每拍各一次无条件读 -> SIMPLE_DUAL_PORT。
//
//  【延迟表】
//    n        : din_vld, din_u = tile_x0+n
//    n+12     : cg_vld, token=(uc,wx,vr,wy)，tok_col=n；同拍发行缓存读地址
//    n+13     : qE/qO -> ra16/rb16；s1_* 标签同拍成立
//    n+14     : vmem[rcol] <= V ; amem[n] <= {rcol,wx}
//    u+LAG    : 读 amem[u] -> hA_*        u+LAG+1 : 读 vmem -> hB_*
//    u+LAG+3  : data_o / de_o
//    LAG 下界 LAG >= 14 + max(源列超前量)；桶形实测 2 -> LAG=20
// =============================================================================
`timescale 1ns/1ps

module ud_tile_core_bil #(
    parameter integer TW     = 160,    // 输出宽度（一条）
    parameter integer SW     = 192,    // 源列窗口宽度（>= TW，16 的倍数）
    parameter integer HEIGHT = 720,
    parameter integer RPB    = 24,     // 行窗口
    parameter integer MARGIN = 8,
    parameter integer LEAD   = 2,
    parameter integer LAG    = 20,
    parameter integer XEXT   = 24,     // 帧尾补扫: 必须 >= LAG+4, 否则 amem[TW-4..TW-1] 不写
    parameter integer XMAR   = 20,     // 源列窗口额外余量（>= 一个 16 列栅格）
    parameter integer K1CFG  = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [11:0] row_v,
    input  wire [11:0] tile_x0,
    output reg         fd_req,
    output reg  [11:0] fd_row,
    output reg  [11:0] fd_x0,      // 本条要读的源列窗口起点（16 对齐）
    input  wire        fd_ack,
    input  wire [31:0] fd_data,
    input  wire        fd_data_vld,
    output reg         de_o,
    output reg  [15:0] data_o,
    output reg         row_done
);

    localparam integer CX2V = 1279;             // 2*cx
    localparam integer FX2V = 750*750;
    localparam integer K1P  = (K1CFG >= 0) ? ((K1CFG + FX2V/2)/FX2V)
                                           : -(((-K1CFG) + FX2V/2)/FX2V);
    localparam integer CY2V = 719;              // 2*cy
    localparam integer B2MAX= (719*719) >> 2;   // (v-cy)^2 的最大值
    localparam integer HALF = RPB/2;
    localparam integer WW   = SW/2;
    localparam integer VWD  = SW + 2;
    localparam integer RLEN = TW + XEXT + 8;   // > LAG+TW+3 且 > XEXT+TW
    localparam integer LATCG= 12;
    localparam [11:0]  XMAX12 = 1280 - SW;   // xs 上限
    localparam [7:0]   SWM8   = SW - 1;      // 最大合法源列索引

    // ---------------- 行窗口基准（与原版一致） ----------------
    wire signed [13:0] b2  = {2'b0, row_v, 1'b0} - CY2V[13:0];
    wire signed [13:0] au2c= ({1'b0, tile_x0, 1'b0} + TW) - CX2V[13:0];
    wire signed [27:0] A2c = (au2c * au2c) >>> 2;
    wire signed [27:0] B2  = (b2  * b2 ) >>> 2;
    wire signed [28:0] R2  = A2c + B2;
    wire signed [47:0] R2w = {{19{R2[28]}}, R2};
    wire signed [47:0] b2w = {{34{b2[13]}}, b2[13:0]};
    wire signed [47:0] dvc = (K1P * R2w * b2w) >>> 25;
    wire signed [23:0] vc_h= { {10{b2[13]}}, b2[13:0] } + (dvc <<< 1) + CY2V[23:0];
    wire signed [23:0] vc_s= vc_h >>> 1;

    wire signed [23:0] bsel  = vc_s - MARGIN - LEAD;
    wire        [11:0] base_t= (bsel < 0)          ? 12'd0 :
                               (bsel > HEIGHT-RPB) ? (HEIGHT-RPB) :
                                                     bsel[11:0];

    // ---------------- 源列窗口起点 xs ----------------
    function signed [31:0] du_of;      // (K1P * R2 * au2) >>> 25
        input signed [28:0] R2f;
        input signed [13:0] au2f;
        reg   signed [47:0] p;
        begin
            p     = R2f * au2f * K1P;
            du_of = p >>> 25;
        end
    endfunction

    wire signed [13:0] au2l = {1'b0, tile_x0, 1'b0} - CX2V[13:0];   // FIX: 与 au2c/au2r 一致, 必须是 2*(x0-cx)
    wire signed [13:0] au2r = {1'b0, tile_x0, 1'b0} + (2*TW) - CX2V[13:0];
    wire signed [27:0] A2l  = (au2l * au2l) >>> 2;
    wire signed [27:0] A2r  = (au2r * au2r) >>> 2;

    wire signed [31:0] xl0 = {20'd0, tile_x0}        + du_of(A2l,        au2l);
    wire signed [31:0] xl1 = {20'd0, tile_x0}        + du_of(A2l+B2MAX,  au2l);
    wire signed [31:0] xr0 = {19'd0, tile_x0 + TW}   + du_of(A2r,        au2r);
    wire signed [31:0] xr1 = {19'd0, tile_x0 + TW}   + du_of(A2r+B2MAX,  au2r);
    wire signed [31:0] xlmin = (xl0 < xl1) ? xl0 : xl1;
    wire signed [31:0] xrmax = (xr0 > xr1) ? xr0 : xr1;

    wire signed [31:0] xsn = (((xlmin - XMAR) >>> 4) <<< 4);
    wire        [11:0] xs_c = (xsn < 0)            ? 12'd0 :
                              (xsn > XMAX12)       ? XMAX12 :
                                                     xsn[11:0];

    // ---------------- 行缓存 ----------------
    reg [31:0] memE [0:HALF*WW-1];
    reg [31:0] memO [0:HALF*WW-1];

    localparam S_IDLE = 0, S_FILL = 1, S_SWEEP = 2;
    reg [2:0]  st;
    reg [11:0] base, vtop, need_top, sv_row, sv_x0;
    reg [11:0] win_x;
    reg        ld_vtop;          // 【单驱动】vtop 只在取数块里被改写
    reg [11:0] vtop_ld;

    // ---------------- 取数引擎 ----------------
    reg        f_busy, f_wait;
    reg [11:0] f_row;
    reg [7:0]  f_col;
    wire [16:0] fslot = ((f_row % RPB) >> 1) * WW;

    always @(posedge clk) begin
        if (!rst_n) begin
            f_busy<=1'b0; f_wait<=1'b0; fd_req<=1'b0;
            f_row<=12'd0; f_col<=8'd0; vtop<=12'd0;
        end else if (ld_vtop) begin
            // 新的窗口基准：整窗从 vtop_ld 重填（vtop 唯一驱动点）
            vtop <= vtop_ld; f_busy <= 1'b0; f_wait <= 1'b0; fd_req <= 1'b0;
        end else if (!f_busy) begin
            fd_req <= 1'b0;
            if (vtop < need_top) begin
                f_busy<=1'b1; f_wait<=1'b1; f_row<=vtop; fd_row<=vtop; fd_req<=1'b1; f_col<=8'd0;
            end
        end else begin
            if (f_wait) begin
                if (fd_ack) begin fd_req<=1'b0; f_wait<=1'b0; end
            end else if (fd_data_vld) begin
                if (f_row[0]) memO[fslot + f_col] <= fd_data;
                else          memE[fslot + f_col] <= fd_data;
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

    ud_coord_gen_dm #(.WIDTH(TW), .HEIGHT(HEIGHT), .K1_VAL(K1CFG), .ROUND_BIAS(128)) u_cg (
        .clk(clk), .rst_n(rst_n),
        .din_vld(sweep_on && (n < TW + XEXT)), .din_u(gu[11:0]), .din_v(sv_row),
        .dout_vld(cg_vld), .dout_ud_q8(cg_ud), .dout_vd_q8(cg_vd),
        .dout_uc(cg_uc), .dout_wx(cg_wx), .dout_vr(cg_vr), .dout_wy(cg_wy),
        .dout_u_pipe(),
        .cfg_a00(357914), .cfg_a01(0), .cfg_a02(-228885965),
        .cfg_a10(0), .cfg_a11(357914), .cfg_a12(-128670062),
        .cfg_k1(K1CFG), .cfg_k2(0), .cfg_p1(0), .cfg_p2(0),
        .cfg_fx(49152000), .cfg_fy(49152000), .cfg_cx(41910272), .cfg_cy(23560192)
    );

    wire [11:0] tok_col = (n >= LATCG) ? (n[11:0] - LATCG[11:0]) : 12'd0;

    // ---------------- 读地址：源列相对窗口起点、行窗口保护 ----------------
    wire signed [12:0] lcx = $signed({1'b0, cg_uc}) - $signed({1'b0, win_x});
    wire        [7:0]  rcol= (lcx < 0)         ? 8'd0 :
                            (lcx > SWM8)       ? SWM8 :
                                                 lcx[7:0];

    wire [11:0] v1 = (cg_vr > HEIGHT-1) ? (HEIGHT-1) : cg_vr;
    wire [11:0] v2 = (v1 >= HEIGHT-1)  ? (HEIGHT-1) : (v1 + 12'd1);
    wire        rval = sweep_on && cg_vld && (v1 >= base) && (v1 < base + RPB);

    wire [11:0] e12 = v1[0] ? v2 : v1;
    wire [11:0] o12 = v1[0] ? (v1 - 12'd1) : v1;
    wire [11:0] slE = (e12 >> 1) % HALF;
    wire [11:0] slO = (o12 >> 1) % HALF;
    wire [16:0] radrE = slE * WW + (rcol >> 1);
    wire [16:0] radrO = slO * WW + (rcol >> 1);

    reg [31:0] qE, qO;
    reg [11:0] v1_d, v2_d;
    reg [7:0]  rcol_d;
    reg        rval_d;
    reg [7:0]  wy_d, wx_d;
    reg [11:0] col_d;
    always @(posedge clk) begin
        qE     <= memE[radrE];
        qO     <= memO[radrO];
        v1_d   <= v1;
        v2_d   <= v2;
        rcol_d <= rcol;
        rval_d <= rval;
        wy_d   <= cg_wy;
        wx_d   <= cg_wx;
        col_d  <= tok_col;
    end

    wire [31:0] qa = v1_d[0] ? qO : qE;
    wire [31:0] qb = v1_d[0] ? qE : qO;
    wire [15:0] ra16 = rcol_d[0] ? qa[31:16] : qa[15:0];
    wire [15:0] rb16 = rcol_d[0] ? qb[31:16] : qb[15:0];
    // v2 在底边会被夹成 HEIGHT-1 = v1：此时 memE 里装的是 v1-1（奇偶 bank 退化为相邻行），
    // rb16 不再是 v1 那一行，必须直接退回 ra16。rot=0 时 v1 到不了 HEIGHT-1，本改动对既有 M2 基线是空操作。
    wire        rb_ok = (v2_d != v1_d) && (v2_d >= base) && (v2_d < base + RPB);
    wire [15:0] rb16e = rb_ok ? rb16 : ra16;

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

    wire [5:0] v_r = mixc(ra16[15:11], rb16e[15:11], wy_d);
    wire [5:0] v_g = mixc(ra16[10:5],  rb16e[10:5],  wy_d);
    wire [5:0] v_b = mixc(ra16[4:0],   rb16e[4:0],   wy_d);
    wire [15:0] vval = {v_r[4:0], v_g, v_b[4:0]};

    reg [15:0] vmem0 [0:VWD-1];
    reg [15:0] vmem1 [0:VWD-1];
    reg [15:0] amem  [0:VWD-1];
    always @(posedge clk) begin
        if (rval_d) begin
            vmem0[rcol_d] <= vval;
            vmem1[rcol_d] <= vval;
            amem[col_d[7:0]] <= {rcol_d, wx_d};
        end
    end

    // ---------------- 水平插值 + 输出 ----------------
    wire        h_en  = sweep_on && (n >= LAG) && (n < TW + LAG);
    wire [11:0] u_out = (n >= LAG) ? (n - LAG[11:0]) : 12'd0;
    wire [15:0] amem_q = amem[u_out[7:0]];

    reg        hA_vld;
    reg [7:0]  hA_uc;
    reg [7:0]  hA_wx;
    always @(posedge clk) begin
        if (!rst_n) begin hA_vld<=1'b0; hA_uc<=8'd0; hA_wx<=8'd0; end
        else begin
            hA_vld <= h_en;
            hA_uc  <= amem_q[15:8];
            hA_wx  <= amem_q[7:0];
        end
    end

    wire [7:0] hB_uc1 = (hA_uc >= SWM8) ? SWM8 : (hA_uc + 8'd1);
    reg        hB_vld;
    reg [7:0]  hB_wx;
    reg [15:0] hB_v0, hB_v1;
    always @(posedge clk) begin
        if (!rst_n) begin hB_vld<=1'b0; hB_wx<=8'd0; hB_v0<=16'd0; hB_v1<=16'd0; end
        else begin
            hB_vld <= hA_vld;
            hB_wx  <= hA_wx;
            hB_v0  <= vmem0[hA_uc];
            hB_v1  <= vmem1[hB_uc1];
        end
    end

    wire [5:0] d_r = mixc(hB_v0[15:11], hB_v1[15:11], hB_wx);
    wire [5:0] d_g = mixc(hB_v0[10:5],  hB_v1[10:5],  hB_wx);
    wire [5:0] d_b = mixc(hB_v0[4:0],   hB_v1[4:0],   hB_wx);

    reg de_d1, de_d2;
    always @(posedge clk) begin
        if (!rst_n) begin de_o<=1'b0; de_d1<=1'b0; de_d2<=1'b0; data_o<=16'd0; end
        else begin
            de_d1  <= h_en;
            de_d2  <= de_d1;
            data_o <= {d_r[4:0], d_g, d_b[4:0]};
            de_o   <= de_d2;
        end
    end

    // ---------------- 主状态机 ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st<=S_IDLE; row_done<=1'b0; base<=0; need_top<=0;
            sweep_on<=1'b0; n<=12'd0; sv_row<=0; sv_x0<=0; win_x<=12'd0; fd_x0<=12'd0;
            ld_vtop<=1'b0; vtop_ld<=12'd0;
        end else begin
            row_done <= 1'b0;
            case (st)
            S_IDLE: begin
                sweep_on <= 1'b0;
                if (start) begin
                    sv_row <= row_v; sv_x0 <= tile_x0;
                    base     <= base_t;
                    need_top <= base_t + RPB;
                    win_x  <= xs_c;  fd_x0 <= xs_c;
                    if (base_t < base || base_t > base + RPB) begin
                        ld_vtop <= 1'b1;  vtop_ld <= base_t;
                    end
                    st <= S_FILL;
                end
                else if (ld_vtop) ld_vtop <= 1'b0;
            end
            S_FILL: begin
                if (ld_vtop) ld_vtop <= 1'b0;                 // 取数块已在上一拍装载 vtop
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