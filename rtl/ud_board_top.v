// ud_board_top.v -- 板级顶层（上板用这个）
//
// 与 ud_tile_sys_top_rt 的区别：那个是"报资源用"的假负载（ar_ready 常数、r_data/r_valid
// 来自 LFSR、系数来自 LFSR）。这里是真正可以接 DDR 控制器与写侧逻辑的顶层：
//   - 真实 DDR 读主口（ar_* / r_*）
//   - 两个时钟域各自同步释放复位
//   - 系数走 cfg_* 输入（RUNTIME_CFG=1，乘法不被常数折叠）
//   - 像素输出附带 out_x0 / out_row，写侧据此把 160 宽的列条带放到帧缓冲正确位置
//
// 输出是 tile-major：先扫完 tile0 的 0..719 行，再 tile1……每行 160 像素。
// 写侧做法：fb[out_row][out_x0 + i] = data_o，i = 本行第几个 de_o。
`timescale 1ns/1ps

module ud_board_top (
    // 时钟与复位
    input  wire         clk,          // 读核域，50 MHz
    input  wire         clk_ddr,      // DDR 域，42 MHz
    input  wire         rst_n,        // 异步复位（内部各域同步释放）

    // 帧控制
    input  wire         frame_start,
    output wire         frame_done,

    // 系数（可由寄存器组驱动；RUNTIME_CFG=1）
    input  wire signed [31:0] cfg_a00, cfg_a01, cfg_a02,
    input  wire signed [31:0] cfg_a10, cfg_a11, cfg_a12,
    input  wire signed [31:0] cfg_h20, cfg_h21, cfg_w0,

    // 帧缓冲页号（ddr 域）：stage 2 由 ud_page_sched 给出；现在接 0 = 原行为
    input  wire [1:0]   page_rd,

    // DDR 读主口
    output wire         ar_valid,
    output wire [27:0]  ar_addr,
    output wire [3:0]   ar_len,
    input  wire         ar_ready,
    input  wire [255:0] r_data,
    input  wire         r_valid,
    input  wire         r_last,

    // 像素输出（tile-major，每行 TW 个像素）
    output wire         de_o,
    output wire [15:0]  data_o,
    output wire [11:0]  out_x0,       // 本行所属 tile 的左列（0,160,...,1120）
    output wire [11:0]  out_row       // 本行输出行号（0..719）
);
    localparam integer TW      = 160;
    localparam integer SW      = 256;
    localparam integer HEIGHT  = 720;
    localparam integer FW      = 1280;
    localparam integer RPB     = 120;
    localparam integer WINHLOG = 1;
    localparam integer LATF    = 29;
    localparam integer LAG     = 20 + LATF;   // 必须 49
    localparam integer K1CFG   = -2248147;    // 标定后改这里（或改成端口）

    // ---------------- 复位同步 ----------------
    wire rst_c_n, rst_d_n;
    ud_reset_sync u_rst_c (.clk(clk),     .arst_n(rst_n), .srst_n(rst_c_n));
    ud_reset_sync u_rst_d (.clk(clk_ddr), .arst_n(rst_n), .srst_n(rst_d_n));

    // ---------------- 行/列调度 ----------------
    wire        start_o, tile_done;
    wire [11:0] row_v, tile_x0;
    wire [3:0]  tile_idx;

    ud_tile_sched #(.TW(TW), .HEIGHT(HEIGHT), .NT(8)) u_sched (
        .clk(clk), .rst_n(rst_c_n), .frame_start(frame_start), .tile_done(tile_done),
        .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .tile_idx(tile_idx), .frame_done(frame_done)
    );

    // [M4-ALIGN] 行号/列条号取【核心输出的延迟版】（与 de_o 同拍），
    // 不再用调度器的 row_v/tile_x0：行间流水后它们会在行内翻页。
    wire [11:0] core_out_row, core_out_x0;
    assign out_x0  = core_out_x0;
    assign out_row = core_out_row;

    // ---------------- 读核 ----------------
    wire        fd_req, fd_ack, fd_data_vld;
    wire [11:0] fd_row, fd_x0;
    wire [31:0] fd_data;
    wire        fd_abort, fd_pop;

    ud_tile_core_m4 #(
        .TW(TW), .SW(SW), .HEIGHT(HEIGHT), .RPB(RPB), .WINHLOG(WINHLOG),
        .MARGIN(24), .LAG(LAG), .LATF(LATF), .K1CFG(K1CFG),
        .RUNTIME_CFG(1), .P_K1(K1CFG)
    ) u_core (
        .clk(clk), .rst_n(rst_c_n),
        .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .fd_abort(fd_abort), .fd_pop(fd_pop),
        .cfg_ux(32'sd65536), .cfg_uv(32'sd0), .cfg_u0(32'sd0),
        .cfg_a00(cfg_a00), .cfg_a01(cfg_a01), .cfg_a02(cfg_a02),
        .cfg_a10(cfg_a10), .cfg_a11(cfg_a11), .cfg_a12(cfg_a12),
        .cfg_h20(cfg_h20), .cfg_h21(cfg_h21), .cfg_w0(cfg_w0),
        .de_o(de_o), .data_o(data_o), .row_done(tile_done),
        .out_row(core_out_row), .out_x0(core_out_x0)
    );

    // ---------------- DDR 读回跨域 ----------------
    ud_row_rd_cdc #(.TW(SW), .FW(FW), .AW(8)) u_rd (
        .clk_c(clk), .rst_c_n(rst_c_n),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0),
        .fd_abort(fd_abort), .fd_pop(fd_pop),
        .fd_ack(fd_ack), .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .clk_d(clk_ddr), .rst_d_n(rst_d_n), .page(page_rd),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

endmodule
