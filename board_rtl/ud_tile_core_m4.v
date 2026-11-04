// =============================================================================
//  ud_tile_core_m4.v -- 读侧列条核心 M3b：M3a + 透视（齐次归一化）
//
//  M3b 相对 M3a 只加一层：ud_persp_front 插在 ud_coord_gen_dm_norm 之前，
//  把 (u,v) 的齐次分子 X/Y 除以 W 得到 Q8.24 归一化坐标，再喂团队核的
//  NORMALIZED_INPUT=1 入口。dm_mapper.v 一行没改。
//
//  恒等 / 纯旋转（H20=H21=0, W0=2^24）时 W≡2^24、r≡2^24，
//  norm = X >>> 4，与 M3a 的 affine_x_q28 >>> 4 逐位相同 —— 新管子不引入回归。
//
//  【时延】ud_persp_front 的 29 拍让 LATCG 从 12 变 12+LATF、LAG 从 20 变 20+LATF，
//  两者间隔仍是 8 拍（写 n-LATCG、读 n-LAG），RLEN 同步加长。
// =============================================================================
//
//  --- 以下为 M3a 原注释 ---
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

module ud_tile_core_m4 #(
    parameter integer TW     = 160,
    parameter integer SW     = 256,    // 每个源行的窗口宽度（16 的倍数）
    parameter integer HEIGHT = 720,
    parameter integer RPB    = 120,    // 行窗口（= 读窗口；必须 < RBUF 才能预取，见下）
    parameter integer MARGIN = 56,     // 【已不再使用】源列窗口左侧余量（M3b 起烘进窗口表，值由 -MG/${MAR} 决定）
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
    // 透视分母（Q8.24）: W = P_W0 + P_H20*u + P_H21*v
    // 恒等/纯旋转: P_H20 = P_H21 = 0, P_W0 = 2^24  ->  W ≡ 2^24
    parameter integer P_H20 = 0, P_H21 = 0, P_W0 = 16777216,
    parameter integer LEAD   = 2,      // 【已不再使用】同上
    // 窗口表断点间隔 = 2^WINHLOG 行（必须与 tools/m3_model.mjs 的 HLOG 一致）
    parameter integer WINHLOG = 1,
    // 0 = 透视系数用参数（仿真/固定角度）；1 = 用 cfg_* 输入（上板运行时换角度）
    // 注意：RUNTIME_CFG=0 时系数是常数，Vivado/PDS 会把乘法折成移位加法 ——
    // 综合报出来的 APM 会比真实上板小，报资源必须用 =1 跑一遍。
    parameter integer RUNTIME_CFG = 0,
    // ud_persp_front 的流水时延；LAG 必须比 LATCG 多 8 拍（写/读不撞同一槽）
    parameter integer LATF   = 29,
    parameter integer LAG    = 20 + LATF,
    parameter integer XEXT   = 0,      // 实测可删：每行只喂 TW 个 token
    parameter integer NT     = 8,      // 列条数（核心自走 8x720 序列用）
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
    // 给跨域封装的旁路观察口（直连版可悬空）
    output wire        fd_abort,       // 本拍放弃当前行（= ld_vtop）
    output wire        fd_pop,         // 本拍从数据口取走一个字
    // 像素域仿射（Q16.16）: 源列 = cfg_ux*tile_x0 + cfg_uv*row_v + cfg_u0
    input  wire signed [31:0] cfg_ux,
    input  wire signed [31:0] cfg_uv,
    input  wire signed [31:0] cfg_u0,
    // 透视/畸变系数（RUNTIME_CFG=1 时生效；=0 时用上面的 P_* 参数）
    input  wire signed [31:0] cfg_a00, cfg_a01, cfg_a02,
    input  wire signed [31:0] cfg_a10, cfg_a11, cfg_a12,
    input  wire signed [31:0] cfg_h20, cfg_h21, cfg_w0,
    output reg         de_o,
    output reg  [15:0] data_o,
    output reg         row_done,
    output reg  [15:0] win_miss,   // 取数窗口未就绪拍数（连续流下应恒为 0）
    // [M4-ALIGN] 与 de_o 同拍的「本行输出行号 / 列条左边界」。写通道（ud_axi_wr_master）
    // 和逐像素 dump 必须用这两个，不能再用 ud_tile_sched 的 row_v/tile_x0 ——
    // 那两个是「当前正在发的行」，行间流水后会在本行还在出像素时就翻页，
    // 导致每行尾巴被写到下一行的地址上（块状错位）。
    output wire [11:0] out_row,
    output wire [11:0] out_x0
);

    localparam integer CX2V = 1279;             // 2*cx
    localparam integer FX2V = 750*750;
    localparam integer K1P  = (P_K1 >= 0) ? ((P_K1 + FX2V/2)/FX2V)
                                          : -(((-P_K1) + FX2V/2)/FX2V);
    localparam integer CY2V = 719;              // 2*cy
    // 行缓存固定 128 行（2^7，取模免费）；行窗口 RPB 必须比它小，多出来的
    // RBUF-RPB 行是【预取保护带】：取数可以跑到 base+RBUF 而不覆盖窗口里还在用的行。
    // 若不留保护带（RPB=RBUF），每行都得在 S_FILL 等一次取数，实测 +30% 帧时间。
    localparam integer RBUF = 128;
    localparam integer HALF = RBUF/2;
    localparam integer WW   = SW/2;
    localparam integer VWD  = SW + 2;
    // RLEN 要覆盖"最后一个被喂进去的 token"的完整时延：TW+XEXT 个 token + LATF
    // 每行扫描长度：最后一个【要输出的 token】是 TW-1，它在 n = TW-1+LAG 被读出，
    // de_o 再晚 3 拍，所以 RLEN = TW+LAG+8 就够（旧值 TW+XEXT+LATF+16 = TW+LAG+20，空转 12 拍/行）。
    // TW+XEXT 那 24 个额外 token 只喂不进输出，保留它们是为了 XEXT 语义，但不再撑长 RLEN。
    localparam integer RLEN = TW + LAG + 8;
    // LATCG = 团队核 LATENCY(12) + 前端时延 LATF；LAG = 20 + LATF（保持 8 拍间隔）
    localparam integer LATCG= 12 + LATF;
    localparam [11:0]  XMAX12 = 1280 - SW;
    localparam [7:0]   SWM8   = SW - 1;

    // 状态机寄存器
    reg [11:0] base, vtop, need_top, sv_row, sv_x0;
    reg        ld_vtop;
    reg [11:0] vtop_ld;

    // ---------------- 窗口基准表（M3b） ----------------
    //  lo(r)/base(v) 由系数生成器离线算好（tools/m3_model.mjs --emit-tab，每 2^WINHLOG 行一个断点），
    //  RTL 只做线性插值（ud_win_tab.v），与模型 buildWinTab()/tabInterp() 逐位一致。
    //  换角度时在帧边界整体换表；上板走 ud_win_tab 的 wr_* 口，仿真用 $readmemh 读 hex。
    //  tile_x0 = 160*t；160 不是 2 的幂，用乘常数精确求 t（205/2^15 对 t=0..7 无误差）。
    wire [2:0] tile_id = (sv_x0 * 205) >>> 15;

    // 系数选择：常量（综合会折叠乘法）或运行时输入
    wire signed [31:0] g_a00 = RUNTIME_CFG ? cfg_a00 : P_A00;
    wire signed [31:0] g_a01 = RUNTIME_CFG ? cfg_a01 : P_A01;
    wire signed [31:0] g_a02 = RUNTIME_CFG ? cfg_a02 : P_A02;
    wire signed [31:0] g_a10 = RUNTIME_CFG ? cfg_a10 : P_A10;
    wire signed [31:0] g_a11 = RUNTIME_CFG ? cfg_a11 : P_A11;
    wire signed [31:0] g_a12 = RUNTIME_CFG ? cfg_a12 : P_A12;
    wire signed [31:0] g_h20 = RUNTIME_CFG ? cfg_h20 : P_H20;
    wire signed [31:0] g_h21 = RUNTIME_CFG ? cfg_h21 : P_H21;
    wire signed [31:0] g_w0  = RUNTIME_CFG ? cfg_w0  : P_W0;

    reg  [11:0] pen_row;                          // 正在取的源行（喂 lo 表）
    reg  [1:0]  f_pre;                            // 取数引擎的查表流水
    wire signed [12:0] lo_tv, base_tv;

    ud_win_tab #(.TBITS(12), .TILES(8), .HLOG(WINHLOG), .TABFILE("wintab_lo.hex")) u_tab_lo (
        .clk(clk), .tile(tile_id), .row(pen_row), .val(lo_tv),
        .wr_en(1'b0), .wr_addr(12'd0), .wr_data(12'd0)
    );

    ud_win_tab #(.TBITS(12), .TILES(8), .HLOG(WINHLOG), .TABFILE("wintab_base.hex")) u_tab_base (
        .clk(clk), .tile(tile_id), .row(sv_row), .val(base_tv),
        .wr_en(1'b0), .wr_addr(12'd0), .wr_data(12'd0)
    );

    localparam signed [12:0] BMAX = HEIGHT - RPB;
    wire signed [12:0] LOLIM = XMAX12;
    wire        [11:0] lo_cl  = (lo_tv   < 0)     ? 12'd0 :
                                (lo_tv   > LOLIM) ? XMAX12 : lo_tv[11:0];
    wire        [11:0] base_t = (base_tv < 0)     ? 12'd0 :
                                (base_tv > BMAX)  ? (HEIGHT-RPB) : base_tv[11:0];

    // ---------------- 行缓存 ----------------
    // 按【行奇偶 × 列奇偶】拆 4 块：总位宽与原来的 2×32bit 相同，不额外占存储。
    // 拆列奇偶是为了【单拍拿到同一行的相邻两列】—— 双线性必须先水平后竖向，
    // 而每个 token 的 (v1, wy) 只对它自己那一列成立，不能借用邻居 token 的竖向样本。
    reg [15:0] memEE [0:HALF*WW-1];             // even 行, even 列
    reg [15:0] memEO [0:HALF*WW-1];             // even 行, odd  列
    reg [15:0] memOE [0:HALF*WW-1];             // odd  行, even 列
    reg [15:0] memOO [0:HALF*WW-1];             // odd  行, odd  列
    reg [11:0] wbase [0:RBUF-1];                // 每个源行的窗口基准（按 row & 127）

    localparam S_IDLE = 0, S_PRE = 1, S_FILL = 2, S_SWEEP = 3, S_FLUSH = 4;
    reg [2:0]  st;
    reg [1:0]  pre_cnt;

    // ---------------- 取数引擎 ----------------
    reg        f_busy, f_wait;
    reg [11:0] f_row;
    reg [7:0]  f_col;

    // 给跨域封装的旁路观察口（直连版可悬空）
    assign fd_abort = ld_vtop;
    assign fd_pop   = f_busy && !f_wait;
    wire [16:0] fslot = ((f_row[6:0]) >> 1) * WW;   // RPB=128 -> 取模免费

    always @(posedge clk) begin
        if (!rst_n) begin
            f_busy<=1'b0; f_wait<=1'b0; fd_req<=1'b0; f_pre<=2'd0;
            f_row<=12'd0; f_col<=8'd0; vtop<=12'd0; pen_row<=12'd0;
        end else if (ld_vtop) begin
            vtop <= vtop_ld; f_busy <= 1'b0; f_wait <= 1'b0; fd_req <= 1'b0; f_pre<=2'd0;
        end else if (!f_busy) begin
            fd_req <= 1'b0;
            case (f_pre)
            2'd0: if (vtop < need_top) begin pen_row <= vtop; f_pre <= 2'd1; end
            // f_pre=1/2 是查表的 2 拍延迟（表内 v0/v1 与插值各寄存一次），f_pre=3 提交
            2'd1: f_pre <= 2'd2;
            2'd2: f_pre <= 2'd3;
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

    reg  [7:0]  tok;
    reg  [11:0] sv_row_p, sv_x0_p;
    reg  [11:0] base_p;
    reg         out_en;
    reg         flush_fill;    // 1 = 本轮排空后回 S_FILL（换条 / 窗口没跟上），0 = 整帧结束回 S_IDLE
    reg         flush_hard;    // 1 = 排空后还要重载行窗口（ld_vtop），0 = 只等取数追上
    wire        run_now = (st == S_SWEEP) || (st == S_FLUSH);
    // 排空末段（最后 LAG+2 个哑 token 已喂完）就停喂，让流水在回到 S_FILL 之前彻底空掉，
    // 否则新一行的 token 0 会和还在飞的哑 token 撞在一起（行首/行尾错位）。
    wire        flush_idle = (st == S_FLUSH) && (tok > (LAG + 2));
    wire        row_end = (tok == TW - 1);
    function [7:0] dtok;
        input [7:0] t;
        input integer k;
        begin dtok = (t >= k) ? (t - k[7:0]) : (t + TW[7:0] - k[7:0]); end
    endfunction
    wire [12:0] gu = {1'b0, sv_x0} + {1'b0, tok};
    wire        sweep_feed = run_now && !flush_idle;
    wire        sweep_on   = run_now;
    wire [11:0] n          = {4'd0, tok};
    wire [7:0]  tk29 = dtok(tok, LATF);
    wire [11:0] u29  = ((tok < LATF) ? sv_x0_p : sv_x0) + {4'd0, tk29};
    wire [11:0] v29  =  (tok < LATF) ? sv_row_p : sv_row;
    wire [7:0]  tk43 = dtok(tok, LATCG + 2);
    wire [11:0] base41 = (tok < LATCG) ? base_p : base;           // rval（= cg_vld 那拍）
    wire [11:0] base43 = (tok < (LATCG + 2)) ? base_p : base;     // rb_ok（再晚 2 拍）
    wire [7:0]  tk49 = dtok(tok, LAG);
    wire [11:0] row51 = (tok < (LAG + 3)) ? sv_row_p : sv_row;
    wire [11:0] x0_51 = (tok < (LAG + 3)) ? sv_x0_p  : sv_x0;
    wire [3:0]  tile_nxt = (sv_row == HEIGHT - 1)
                           ? ((tile_id == NT - 1) ? 4'd0 : {1'b0, tile_id} + 4'd1)
                           : {1'b0, tile_id};
    wire [11:0] row_nxt  = (sv_row == HEIGHT - 1) ? 12'd0 : sv_row + 12'd1;
    wire [11:0] x0_nxt   = {8'd0, tile_nxt} * TW;
    wire        frame_end = row_end && (sv_row == HEIGHT - 1) && (tile_id == NT - 1);
    wire signed [12:0] base_tv_next;
    ud_win_tab #(.TBITS(12), .TILES(8), .HLOG(WINHLOG), .TABFILE("wintab_base.hex")) u_tab_nx (
        .clk(clk), .tile(tile_nxt[2:0]), .row(row_nxt), .val(base_tv_next),
        .wr_en(1'b0), .wr_addr(12'd0), .wr_data(12'd0)
    );
    wire [11:0] base_nxt = (base_tv_next < 0)    ? 12'd0 :
                           (base_tv_next > BMAX) ? (HEIGHT - RPB) : base_tv_next[11:0];

    // ---------------- 透视前端（M3b） ----------------
    //   X = a00*u + a01*v + a02 (Q4.28)
    //   Y = a10*u + a11*v + a12 (Q4.28)
    //   W = w0  + h20*u + h21*v (Q8.24)
    //   norm_x/y = (X/Y * floor(2^48/W)) >>> 28   时延 LATF = 29
    wire               f_vld;
    wire signed [31:0] f_nx, f_ny;
    wire               f_ovf;

    ud_persp_front #(.LATF(LATF)) u_pf (
        .clk(clk), .rst_n(rst_n), .ce(1'b1),
        .cfg_a00(g_a00), .cfg_a01(g_a01), .cfg_a02(g_a02),
        .cfg_a10(g_a10), .cfg_a11(g_a11), .cfg_a12(g_a12),
        .cfg_h20(g_h20), .cfg_h21(g_h21), .cfg_w0(g_w0),
        .din_vld(sweep_feed), .din_u(gu[11:0]), .din_v(sv_row),
        .dout_vld(f_vld), .norm_x(f_nx), .norm_y(f_ny), .norm_ovf(f_ovf)
    );

    // ---------------- 坐标发生器（团队核 NORMALIZED_INPUT=1） ----------------
    wire        cg_vld;
    wire [18:0] cg_ud, cg_vd;
    wire [11:0] cg_uc, cg_vr;
    wire [7:0]  cg_wx, cg_wy;

    ud_coord_gen_dm_norm #(.WIDTH(TW), .HEIGHT(HEIGHT), .K1_VAL(P_K1), .ROUND_BIAS(128)) u_cg (
        .clk(clk), .rst_n(rst_n),
        .din_vld(f_vld), .din_u(u29), .din_v(v29),
        .norm_x(f_nx), .norm_y(f_ny), .norm_overflow(f_ovf),
        .dout_vld(cg_vld), .dout_ud_q8(cg_ud), .dout_vd_q8(cg_vd),
        .dout_uc(cg_uc), .dout_wx(cg_wx), .dout_vr(cg_vr), .dout_wy(cg_wy),
        .dout_u_pipe(),
        .cfg_a00(g_a00), .cfg_a01(g_a01), .cfg_a02(g_a02),
        .cfg_a10(g_a10), .cfg_a11(g_a11), .cfg_a12(g_a12),
        .cfg_k1(P_K1), .cfg_k2(P_K2), .cfg_p1(P_P1), .cfg_p2(P_P2),
        .cfg_fx(P_FX), .cfg_fy(P_FY), .cfg_cx(P_CX), .cfg_cy(P_CY)
    );

    wire [11:0] tok_col = {4'd0, dtok(tok, LATCG)};   // 写索引交给后面的 col_d/col_dd 两级，与旧版一致

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

    wire        rval = run_now && cg_vld && (v1 >= base41) && (v1 < base41 + RPB);

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
    wire        rb_ok = (v2_dd != v1_dd) && (v2_dd >= base43) && (v2_dd < base43 + RPB);
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

    wire        h_en  = run_now && out_en;
    wire [11:0] u_out = {4'd0, tk49};
    wire [15:0] buf_q = vbuf[u_out[7:0]];

    reg [15:0] s1, s2;
    always @(posedge clk) begin
        if (!rst_n) begin s1<=16'd0; s2<=16'd0; end
        else begin s1 <= buf_q; s2 <= s1; end
    end

    // [M4-ALIGN] 行号/列条号随像素走（de_o = feed + LAG + 3）
    assign out_row = row51;
    assign out_x0  = x0_51;

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


`ifdef DBG
    // 调试：打印指定 (row, u 区间) 的坐标与窗口
    always @(posedge clk) begin
        if (rst_n && cg_vld && (sv_row == `DBG_ROW) && (gu >= `DBG_U0) && (gu <= `DBG_U1))
            $display("DBG u=%0d uc=%0d wx=%0d vr=%0d wy=%0d v1=%0d v2=%0d base=%0d wbE=%0d wbO=%0d cE0=%0d cE1=%0d cO0=%0d cO1=%0d rval=%0d",
                     gu, cg_uc, cg_wx, cg_vr, cg_wy, v1, v2, base, wbE, wbO, cE0, cE1, cO0, cO1, rval);
    end
    always @(posedge clk) begin
        if (rst_n && (f_pre == 2'd3) && !f_busy && (sv_row == `DBG_ROW))
            $display("ISSUE tilex0=%0d vtop=%0d lo_cl=%0d lo_tv=%0d tab_v0=%0d d=%0d frac=%0d pen=%0d",
                     sv_x0, vtop, lo_cl, lo_tv, u_tab_lo.v0_s, u_tab_lo.d_r, u_tab_lo.frac_r, pen_row);
        if (rst_n && sweep_on && (n == 0) && (sv_row == `DBG_ROW))
            $display("WBASE tilex0=%0d row=%0d base=%0d wb0..6=%0d %0d %0d %0d %0d %0d %0d",
                     sv_x0, sv_row, base, wbase[0], wbase[1], wbase[2], wbase[3], wbase[4], wbase[5], wbase[6]);
    end
    always @(posedge clk) begin
        if (rst_n && rval_dd && (sv_row == `DBG_ROW))
            $display("DBG2 n=%0d col_dd=%0d v1=%0d v2=%0d rb=%0d pE0=%h pE1=%h hE=%h hO=%h wy=%0d vval=%h",
                     n, col_dd, v1_dd, v2_dd, rb_ok, pE0, pE1, hE, hO, wy_dd, vval);
    end
`endif

`ifdef DBGT
    // 逐 token 追踪（只在 +define+DBGT 时启用，窗口由 DBGU0..DBGU1 / DBGV0..DBGV1 给）
    always @(posedge clk) begin
        if (rst_n && cg_vld && run_now && (cg_uc >= `DBGU0) && (cg_uc <= `DBGU1) &&
            (v1 >= `DBGV0) && (v1 <= `DBGV1))
            $display("CGc row=%0d x0=%0d tok=%0d tk=%0d u29=%0d v29=%0d uc=%0d wx=%0d vr=%0d wy=%0d v1=%0d v2=%0d base=%0d b41=%0d wbE=%0d wbO=%0d cE0=%0d cE1=%0d cO0=%0d cO1=%0d rval=%0d vtop=%0d",
                     sv_row, sv_x0, tok, dtok(tok, LATCG), u29, v29, cg_uc, cg_wx, cg_vr, cg_wy, v1, v2, base, base41, wbE, wbO, cE0, cE1, cO0, cO1, rval, vtop);
    end
    always @(posedge clk) begin
        if (rst_n && rval_dd && (col_dd >= `DBGN0) && (col_dd <= `DBGN1) &&
            (v1_dd >= `DBGV0) && (v1_dd <= `DBGV1))
            $display("WRc tok=%0d v1=%0d v2=%0d qEE=%h qEO=%h qOE=%h qOO=%h pE0=%h pE1=%h pO0=%h pO1=%h hE=%h hO=%h hE_r=%h hO_r=%h ra=%h rb=%h rb_ok=%0d wy=%0d wx=%0d vval=%h",
                     col_dd, v1_dd, v2_dd, qEE, qEO, qOE, qOO, pE0, pE1, pO0, pO1, hE, hO, hE_r, hO_r, ra16, rb16, rb_ok, wy_dd, wx_d, vval);
    end
`endif

`ifdef DBG2
    // ---- 行级探针（只在 +define+DBG2 时启用）：取数就绪度 / 未加载行读 / 行边界 ----
    integer dbg_unl, dbg_nor;
    always @(posedge clk) begin
        if (!rst_n) begin dbg_unl <= 0; dbg_nor <= 0; end
        else if (row_end && run_now) begin dbg_unl <= 0; dbg_nor <= 0; end
        else if (run_now && cg_vld) begin
            if (v1 >= vtop) dbg_unl <= dbg_unl + 1;
            if (!rval)      dbg_nor <= dbg_nor + 1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && row_end && run_now)
            $display("RSUM tile=%0d x0=%0d row=%0d vtop=%0d need=%0d base=%0d unl=%0d nor=%0d wm=%0d",
                     tile_id, sv_x0, sv_row, vtop, need_top, base, dbg_unl, dbg_nor, win_miss);
    end
    // 取数引擎按阶段拆账：ack 等待 / 数据流 / 空转（每行 128 字之外的那部分到底花在哪）
    integer dbg_ack_c, dbg_beat_c, dbg_idle_c;
    always @(posedge clk) begin
        if (!rst_n) begin dbg_ack_c <= 0; dbg_beat_c <= 0; dbg_idle_c <= 0; end
        else if (f_busy && f_wait)                     dbg_ack_c  <= dbg_ack_c + 1;
        else if (f_busy && fd_data_vld)                dbg_beat_c <= dbg_beat_c + 1;
        else if (!f_busy && (vtop < need_top))         dbg_idle_c <= dbg_idle_c + 1;
    end
    integer dbg_de, dbg_he;
    always @(posedge clk) begin
        if (!rst_n) begin dbg_de <= 0; dbg_he <= 0; end
        else begin
            if (de_o) dbg_de <= dbg_de + 1;
            if (h_en) dbg_he <= dbg_he + 1;
        end
    end
    always @(posedge clk) begin
        if (rst_n && (st == S_FLUSH) && (tok == LAG + 2))
            $display("FLUSHEND t=%0t de=%0d he=%0d tok=%0d fill=%0d", $time, dbg_de, dbg_he, tok, flush_fill);
        if (rst_n && (st == S_SWEEP) && row_end && (sv_row == 12'd719) && (tile_id == 3'd7))
            $display("FETCHSTATCY ack=%0d beat=%0d idle=%0d", dbg_ack_c, dbg_beat_c, dbg_idle_c);
        if (rst_n && (st == S_FILL) && (vtop >= need_top))
            $display("FILLDONE t=%0t row=%0d tile=%0d vtop=%0d need=%0d base=%0d de=%0d", $time, sv_row, tile_id, vtop, need_top, base, dbg_de);
    end
`endif

    // ---------------- 主状态机：帧启动 + 连续 token 流 ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st<=S_IDLE; row_done<=1'b0; base<=12'd0; base_p<=12'd0; need_top<=12'd0; pre_cnt<=2'd0;
            tok<=8'd0; sv_row<=12'd0; sv_x0<=12'd0; sv_row_p<=12'd0; sv_x0_p<=12'd0;
            out_en<=1'b0; ld_vtop<=1'b0; vtop_ld<=12'd0; win_miss<=16'd0;
            flush_fill<=1'b0; flush_hard<=1'b0;
        end else begin
            row_done <= 1'b0;
            if (ld_vtop) ld_vtop <= 1'b0;
            case (st)
            S_IDLE: begin
                out_en <= 1'b0;
                if (start) begin
                    sv_row  <= row_v;
                    sv_x0   <= tile_x0;
                    pre_cnt <= 2'd2;
                    st      <= S_PRE;
                end
            end
            S_PRE: begin
                if (pre_cnt != 2'd0) pre_cnt <= pre_cnt - 1'b1;
                else begin
                    base     <= base_t;
                    base_p   <= base_t;
                    need_top <= base_t + RPB;
                    if (base_t < base || base_t > base + RPB) begin
                        ld_vtop <= 1'b1;  vtop_ld <= base_t;
                    end
                    st <= S_FILL;
                end
            end
            S_FILL: begin
                // ld_vtop 那一拍 vtop 还是旧值（重载在下一拍才生效），必须先放行一拍再判
                if (!ld_vtop && (vtop >= need_top)) begin
                    tok    <= 8'd0;
                    out_en <= 1'b0;
                    st     <= S_SWEEP;
                end
            end
            S_SWEEP: begin
                if (tok == LAG - 1) out_en <= 1'b1;
                if (vtop < need_top) win_miss <= win_miss + 16'd1;
                if (row_end) begin
                    tok      <= 8'd0;
                    row_done <= 1'b1;
                    sv_row_p <= sv_row;  sv_x0_p <= sv_x0;  base_p <= base;
                    sv_row   <= row_nxt;
                    sv_x0    <= x0_nxt;
                    base     <= base_nxt;
                    need_top <= base_nxt + RPB;
                    // 【行间流水 · 换条】换条前窗口要整段重载（base 从 ~600 跳回 ~0），
                    // 而流水里有 LAG 个 token 还没出来 —— 必须先排空再重载窗口，否则
                    //   1) 新条头 120 行全在读未装载的行（旧 dump 里 tile1..7 行 0..150 全错）；
                    //   2) 重载会立刻改写 wbase[row&127]：上一行尾巴要的源行 672 与
                    //      新条要的行 32 同槽（672&127 == 32），窗口基准被换掉 → 行尾横移。
                    // 所以 ld_vtop 推迟到 S_FLUSH 排空之后再发。
                    if (sv_row == HEIGHT - 1) begin
                        // 换条：窗口整段重载（base 从 ~600 跳回 ~0），必须排空 + 重载
                        flush_fill <= (tile_id != NT - 1);
                        flush_hard <= 1'b1;
                        st <= S_FLUSH;
                    end else if ((base_nxt < base) || (base_nxt > base + RPB)) begin
                        // 行窗口跳变：同样要排空 + 重载
                        flush_fill <= 1'b1;  flush_hard <= 1'b1;
                        st <= S_FLUSH;
                    end else if (vtop < base_nxt + RPB) begin
                        // 取数没跟上：排空后等窗口（不重载）。这就是行间流水唯一需要的背压，
                        // 只在取数落后时才付这 ~90 拍；取数跟得上时三行都无缝续行。
                        flush_fill <= 1'b1;  flush_hard <= 1'b0;
                        st <= S_FLUSH;
                    end
                end else tok <= tok + 1'b1;
                // 预取目标：不再要求 vtop == need_top 才推进（那会在每行之间留 1~2 拍空档，
                // 取数引擎每行白等一次，实测 128 字/行被拖到 166 拍/行 > 160，扫描侧就总在排水）。
                // 上限仍是 base+RBUF-1：行缓存是 base..base+127，行 base+128 才与 base 同槽，
                // 所以 need_top 停在 base+127 不会踩到还在读的行。
                if (!row_end && !f_busy && (need_top < base + RBUF - 1) && (base > 0) &&
                    (base < HEIGHT - RPB) && (vtop < HEIGHT))
                    need_top <= need_top + 1'b1;
            end
            // 【帧尾/换条】tok 数的是「喂进去的 token」：喂到 LAG-1 时本行最后
            // 一个 token 已被读出（tk49 = 159），再喂就是垃圾，所以 out_en 在这里落，
            // 状态机再等 3 拍到 de_o 把那一个像素送出来就收工。
            S_FLUSH: begin
                if (tok == LAG - 1) out_en <= 1'b0;
                // 喂到 LAG+2 把本行最后一个 token 顶出来，再空转 LATCG+2 拍把流水排干净，
                // 然后才重载窗口 / 等取数（此刻写 wbase、行缓存不会踩到还在用的行）
                if (tok == LAG + LATCG + 4) begin
                    tok <= 8'd0;
                    if (flush_fill) begin
                        if (flush_hard) begin ld_vtop <= 1'b1;  vtop_ld <= base; end
                        st <= S_FILL;
                    end else st <= S_IDLE;
                end else tok <= tok + 1'b1;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
