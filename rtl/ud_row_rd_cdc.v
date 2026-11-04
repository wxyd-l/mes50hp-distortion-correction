// ud_row_rd_cdc.v -- 行取数跨时钟域封装（M4 重写版：双槽行缓冲 + 字级流水握手）
//
// 为什么重写（board_readiness_audit.md §A1）：旧版"自由流动异步 FIFO"有三个缺陷
//   1. 请求靠 fd_req 电平翻转 -> 核心把 fd_req 拉高 2 拍 -> 翻转两次 -> 突发次数看相位；
//   2. ren = !rempty 自动出队 -> 核心不在接收态时字被静默弹掉；
//   3. wen 不看 wfull -> 溢出覆盖；abort 残字会串到下一行。
//
// 新结构：
//   - 写侧（clk_d）把字写进双槽行缓冲，全局字指针 wtotal 用格雷码连续发布；
//   - 读侧（clk_c）按 (发布的 wtotal - 自己的 rtotal) 取数，只取到发布位置为止：
//     **流式重叠**（不等整行写完就能读），且绝不多取；
//   - 请求方向用【上升沿检测】，一个请求恰好一次突发；
//   - abort：把 rtotal 推到本行边界（整行作废），不数字数、不串行。
//
// 协议：fd_req 拉高(保持到 fd_ack) -> fd_ack 一拍 -> 之后 fd_pop 每拍取一个字
//       abort：fd_abort 一拍 -> 当前行作废
`timescale 1ns/1ps

module ud_row_rd_cdc #(
    parameter integer TW = 256,     // 行宽（像素），DATA_W = TW/2 个字
    parameter integer FW = 1280,
    parameter integer AW = 8        // 保留以兼容旧实例化，不再使用
) (
    input  wire         clk_c,
    input  wire         rst_c_n,
    input  wire         fd_req,
    input  wire [11:0]  fd_row,
    input  wire [11:0]  fd_x0,
    input  wire         fd_abort,
    input  wire         fd_pop,
    output reg          fd_ack,
    output wire [31:0]  fd_data,
    output wire         fd_data_vld,
    input  wire         clk_d,
    input  wire         rst_d_n,
    input  wire [1:0]   page,           // 帧缓冲页号（ddr 域；随请求锁存）
    output wire         ar_valid,
    output wire [27:0]  ar_addr,
    output wire [3:0]   ar_len,
    input  wire         ar_ready,
    input  wire [255:0] r_data,
    input  wire         r_valid,
    input  wire         r_last
);
    localparam integer DATA_W = TW/2;
    localparam integer W      = 12;                 // 字指针位宽（须 > 2*DATA_W）

    function [W-1:0] bin2gray; input [W-1:0] b;
        begin bin2gray = b ^ (b >> 1); end
    endfunction
    function [W-1:0] gray2bin; input [W-1:0] g;
        integer i;
        begin
            gray2bin[W-1] = g[W-1];
            for (i = W-2; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    // ---------------- 双槽行缓冲 ----------------
    reg [31:0] buf0 [0:DATA_W-1];
    reg [31:0] buf1 [0:DATA_W-1];

    // ---------------- 字指针 ----------------
    reg  [W-1:0] wtotal;            // 写侧（clk_d）
    wire [W-1:0] wtotal_gray = bin2gray(wtotal);

    reg  [W-1:0] rtotal;            // 读侧（clk_c）
    reg  [W-1:0] wtot_s1, wtot_s2;
    wire [W-1:0] wtot_bin = gray2bin(wtot_s2);
    wire [W-1:0] avail    = wtot_bin - rtotal;
    wire [6:0]   roff     = rtotal[6:0];

    // ---------------- 核心域 ----------------
    reg        req_seen;
    reg        req_tog;
    reg [11:0] req_row, req_x0;
    reg        outstanding;
    reg        skip_req;
    wire       req_edge_c = fd_req && !req_seen;

    assign fd_data     = rtotal[7] ? buf1[roff] : buf0[roff];
    assign fd_data_vld = (avail != 0) && !skip_req;

    always @(posedge clk_c) begin
        if (!rst_c_n) begin
            req_seen <= 1'b0; req_tog <= 1'b0; fd_ack <= 1'b0;
            outstanding <= 1'b0; rtotal <= {W{1'b0}};
            wtot_s1 <= {W{1'b0}}; wtot_s2 <= {W{1'b0}};
            skip_req <= 1'b0; req_row <= 12'd0; req_x0 <= 12'd0;
        end else begin
            fd_ack  <= 1'b0;
            wtot_s1 <= wtotal_gray;
            wtot_s2 <= wtot_s1;

            if (!fd_req) req_seen <= 1'b0;

            // 正常取字
            if (fd_pop && fd_data_vld && !fd_abort) begin
                rtotal <= rtotal + 1'b1;
                if (roff == DATA_W-1) outstanding <= 1'b0;
            end

            // abort -> 本行剩余作废
            if (fd_abort && outstanding) begin
                outstanding <= 1'b0;
                skip_req    <= 1'b1;
            end

            // 作废推进：字一到就丢，直到本行边界
            if (skip_req && (avail != 0)) begin
                rtotal <= rtotal + 1'b1;
                if (roff == DATA_W-1) skip_req <= 1'b0;
            end

            // 受理新请求（作废没走完不收）
            if (req_edge_c && !outstanding && !skip_req) begin
                req_seen    <= 1'b1;
                req_tog     <= ~req_tog;
                req_row     <= fd_row;
                req_x0      <= fd_x0;
                fd_ack      <= 1'b1;
                outstanding <= 1'b1;
            end
        end
    end

    // ---------------- DDR 域 ----------------
    reg        tog_s2, tog_s1, tog_s0;
    reg        pend, issued;
    reg [11:0] rd_row, rd_x0;
    reg [1:0]  rd_page;
    wire       rd_ack;
    wire       w_vld;
    wire [31:0] w_dat;
    wire       rd_req = pend;
    wire       req_edge_d = tog_s2 ^ tog_s1;

    always @(posedge clk_d) begin
        if (!rst_d_n) begin tog_s2 <= 1'b0; tog_s1 <= 1'b0; tog_s0 <= 1'b0; end
        else begin tog_s2 <= tog_s1; tog_s1 <= tog_s0; tog_s0 <= req_tog; end
    end

    always @(posedge clk_d) begin
        if (!rst_d_n) begin
            pend <= 1'b0; issued <= 1'b0; rd_row <= 12'd0; rd_x0 <= 12'd0;
            rd_page <= 2'd0; wtotal <= {W{1'b0}};
        end else begin
            if (req_edge_d && !pend && !issued) begin
                pend   <= 1'b1;
                rd_row <= req_row;
                rd_x0  <= req_x0;
                rd_page <= page;        // 与请求同拍锁存，避免一帧内跨页
            end
            if (rd_ack) begin
                pend   <= 1'b0;
                issued <= 1'b1;
            end
            if (w_vld && issued) begin
                wtotal <= wtotal + 1'b1;
                if (wtotal[6:0] == DATA_W-1) issued <= 1'b0;
            end
        end
    end

    always @(posedge clk_d) begin
        if (w_vld && issued) begin
            if (wtotal[7]) buf1[wtotal[6:0]] <= w_dat;
            else           buf0[wtotal[6:0]] <= w_dat;
        end
    end

    ud_ddr_row_rd #(.TW(TW), .FW(FW)) u_rd (
        .clk(clk_d), .rst_n(rst_d_n), .tile_x0(rd_x0), .page(rd_page),
        .fd_req(rd_req), .fd_row(rd_row), .fd_ack(rd_ack),
        .fd_data(w_dat), .fd_data_vld(w_vld),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

endmodule
