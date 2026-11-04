// =============================================================================
//  ud_ddr_row_rd.v -- 从 DDR 突发读取一条图的一行（320 B = 10 个 32 字节拍）
//
//  为什么不用团队 pango_read_bridge.sv 的单拍版本:
//    它 arlen=0, 一次只取 32 B。一行 320 B 要 10 次串行事务, 每次都有 DDR
//    往返延迟, 10 x ~20 拍 = 200 拍 > 扫列 176 拍 -> 带不够。
//    这里用一次 10 拍突发, 回来后 1 拍 1 个 32 B, 10 拍拿完。
//
//  地址约定（必须上板核对）:
//    源帧基址 0, RGB565 每像素 2 B, 每行 FW=1280 像素 = 2560 B。
//    本模块输出的 ar_addr 是 DDR 地址（按 4 字节字计）：
//        word_addr = fd_row * (FW/2) + tile_x0/2
//    帧缓冲实际基址由上层加偏移; 32 字节对齐由 x0 为 16 的倍数保证。
//
//  时序: 请求 -> AR -> 10 拍收集 -> 80 拍吐出(每拍 2 像素) -> 空闲
// =============================================================================
`timescale 1ns/1ps
module ud_ddr_row_rd #(
    parameter integer TW = 160,
    parameter integer FW = 1280
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] tile_x0,
    // 与 ud_tile_core 的行取数接口
    input  wire        fd_req,
    input  wire [11:0] fd_row,
    output reg         fd_ack,
    output reg  [31:0] fd_data,
    output reg         fd_data_vld,
    // 帧缓冲页号：一页 4 MB，页号占地址 [27:22]。
    // 页内偏移 wa = fd_row*(FW/2) + tile_x0/2（1280×720 时最大 460720 < 2^22）。
    input  wire [1:0]  page,
    // 简化 DDR 读接口（突发）
    output reg         ar_valid,
    output reg  [27:0] ar_addr,
    output wire [3:0]  ar_len,
    input  wire        ar_ready,
    input  wire [255:0] r_data,
    input  wire        r_valid,
    input  wire        r_last
);
    localparam integer BEATS = TW/16;        // 160/16 = 10 个 32B 拍
    localparam integer WORDS = TW/2;         // 80 个 32 位字

    assign ar_len = BEATS - 1;

    localparam S_IDLE = 0, S_AR = 1, S_RECV = 2, S_SEND = 3, S_DONE = 4;
    reg [1:0]  st;
    reg [3:0]  bi;                            // 拍计数
    reg [6:0]  wi;                            // 吐字计数
    reg [255:0] beat_buf [0:BEATS-1];

    wire [27:0] wa    = fd_row * (FW/2) + (tile_x0 >> 1);   // 页内偏移
    wire [27:0] wa_pg = {4'b0000, page, wa[21:0]};           // 加页号 -> DDR 地址

    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; fd_ack <= 1'b0; fd_data <= 0; fd_data_vld <= 1'b0;
            ar_valid <= 1'b0; ar_addr <= 0; bi <= 0; wi <= 0;
        end else begin
            case (st)
            S_IDLE: begin
                fd_ack <= 1'b0; fd_data_vld <= 1'b0; ar_valid <= 1'b0;
                if (fd_req) begin
                    ar_addr  <= wa_pg;
                    ar_valid <= 1'b1;
                    bi       <= 0;
                    fd_ack   <= 1'b1;        // 告诉 core 已经受理
                    st       <= S_AR;
                end
            end
            S_AR: begin
                fd_ack <= 1'b0;
                if (ar_ready) begin
                    ar_valid <= 1'b0;
                    st <= S_RECV;
                end
            end
            S_RECV: begin
                if (r_valid) begin
                    beat_buf[bi] <= r_data;
                    bi <= bi + 1'b1;
                    if (bi == BEATS-1 || r_last) begin
                        wi <= 0;
                        st <= S_SEND;
                    end
                end
            end
            S_SEND: begin
                fd_data     <= beat_buf[wi >> 3][ (wi[2:0])*32 +: 32 ];
                fd_data_vld <= 1'b1;
                if (wi == WORDS-1) begin wi <= 0; st <= S_DONE; end
                else               wi <= wi + 1'b1;
            end
            S_DONE: begin
                fd_data_vld <= 1'b0;   // 最后一个 word 在这里才关
                st <= S_IDLE;
            end
            endcase
        end
    end
endmodule
