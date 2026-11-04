// ud_axi_wr_master.v -- M4 像素流 -> AXI 写突发（按拍数驱动，适配本工程 DDR3 IP）
//
// 为什么是"按拍数驱动"而不是标准 AXI 的 wvalid/wready 握手：
//   本工程的 DDR3_50H IP 写通道【没有 axi_wvalid 输入，也没有 wlast 输入】：
//       input  axi_wdata / axi_wstrb
//       output axi_wready / axi_wusero_id / axi_wusero_last
//   => 只要 wready 为高，那一拍的数据就被取走，master 说什么都没用；
//   => 突发边界由从设备的 wusero_last 报回来（awlen+1 只当自检）。
//   旧版 S_W 状态机是 `if (!wvalid) wvalid<=1; else if (wready) ...`，
//   进入 S_W 的第一拍 wvalid=0 而 wdata 还停着上一行的末拍 —— 接到这个 IP 上
//   会被照收一口，整行数据丢/重一拍。这里改成：
//       * 进入 S_AW 时就把第 0 拍预装到 wdata；
//       * 只在 wready 为高时前移（wready 就是"取走"）；
//       * 结束条件 = 从设备的 wusero_last 或 数满 awlen+1，两者不一致计 perr_cnt。
//
// 每个 tile 的一行 = 160 像素 = 320 B = 10 拍 x 32 B，awlen = 9。
//     word_addr = frame_base + (out_row * FW + out_x0) / 2   （地址单位 4 B = 2 像素）
// 跨时钟域：像素流在 clk_c(50 MHz)，AXI 在 clk_d(100 MHz)。双槽 256-bit 行缓冲，
// 写侧攒满 10 拍发布，读侧用 cslot/pslot 判"有一行可取"，地址按槽分开存。
//
// [M4-HOLD] 行缓冲改成显式寄存器（2026-11-03 晚）：
//   旧版写成 reg [DW-1:0] buf0 [0:BEATS-1]，综合成分布式 RAM（ram16x1d）。
//   那批 RAM 落在 CLMS，累积寄存器 acc 落在 CLMA，两个时钟脊差 1.30 ns，同拍写入
//   的数据"早到"1.09 ns，hold 违约（report_timing：
//       acc[156] -> buf0_5_28/ram16x1d/WD，Clock Skew 1.297，Slack -1.089）。
//   布线器连跑 6 轮 hold fix（215 s）也压不下去，整版留 33 条 hold 违约。
//   改成显式寄存器后端点回到 CLMA 内部，交回常规 hold 修复处理。
//   代价：5120 个 FF（器件 64200 的 8%），分布式 RAM 从 2605 降到 0。
//   BEATS 固定 10（PPR=160 / DW=256），不要再改。
`timescale 1ns/1ps

module ud_axi_wr_master #(
    parameter integer AW    = 28,
    parameter integer DW    = 256,
    parameter integer FW    = 1280,
    parameter integer PPR   = 160,
    parameter integer BEATS = 10,
    parameter [3:0]   ID    = 4'd1
) (
    input  wire          clk_c,
    input  wire          rst_c_n,
    input  wire          de,
    input  wire [15:0]   pix,
    input  wire [11:0]   out_x0,
    input  wire [11:0]   out_row,
    input  wire [AW-1:0] frame_base,

    input  wire          clk_d,
    input  wire          rst_d_n,
    output reg           awvalid,
    output reg  [AW-1:0] awaddr,
    output reg  [3:0]    awlen,
    output wire [3:0]    awid,
    input  wire          awready,
    output wire          wvalid,
    output reg  [DW-1:0] wdata,
    output wire [DW/8-1:0] wstrb,
    input  wire          wready,
    input  wire          wusero_last,

    output reg  [15:0]   hdr_cnt,
    output reg  [15:0]   drop_cnt,
    output reg  [15:0]   perr_cnt
);
    // ---------------- 双槽行缓冲（显式寄存器，不是 RAM） ----------------
    // [M4-HOLD2] 去掉中间级 acc：旧版先攒 16 像素到 acc 再整拍拷贝进 b*_k，
    //   综合出来 acc(CLMA) -> b*_k(CLMS) 是极短的 FF->FF 路径，两条时钟脊差 1.3 ns，
    //   hold -303 ps / 12 条压不下去（上一版 90 条 / -1089 ps）。
    //   现在直接按拍写目标 bank 的 16 位切片（b_k[pcnt*16 +: 16] <= pix），
    //   源变成 pix 且中间多一级 160 选 1 的译码，路径变长、hold 余量随之变大；
    //   顺带省掉 256 个 FF。功能逐位不变（run_wrback 已验证）。
    reg [DW-1:0] b0_0, b0_1, b0_2, b0_3, b0_4, b0_5, b0_6, b0_7, b0_8, b0_9;
    reg [DW-1:0] b1_0, b1_1, b1_2, b1_3, b1_4, b1_5, b1_6, b1_7, b1_8, b1_9;
    reg [AW-1:0]        addr_slot [0:1];
    reg                 cslot;          // 消费者当前槽

    // 读侧选择：s = 槽号，i = 本突发第几拍
    function [DW-1:0] pick;
        input       s;
        input [3:0] i;
        begin
            case (i)
            4'd0: pick = s ? b1_0 : b0_0;
            4'd1: pick = s ? b1_1 : b0_1;
            4'd2: pick = s ? b1_2 : b0_2;
            4'd3: pick = s ? b1_3 : b0_3;
            4'd4: pick = s ? b1_4 : b0_4;
            4'd5: pick = s ? b1_5 : b0_5;
            4'd6: pick = s ? b1_6 : b0_6;
            4'd7: pick = s ? b1_7 : b0_7;
            4'd8: pick = s ? b1_8 : b0_8;
            4'd9: pick = s ? b1_9 : b0_9;
            default: pick = {DW{1'b0}};
            endcase
        end
    endfunction

    // ---------------- 写侧 clk_c ----------------
    reg [3:0]    pcnt;
    reg [3:0]    bidx;
    reg          pslot;
    reg          cslot_s1, cslot_s2;
    wire         cslot_sync = cslot_s2;

    // 地址单位 = DQ_WIDTH/8 = 4 B = 2 个像素（与 fram_buf 的 DDR_ADDR_OFFSET=FW/2 一致）
    wire [AW-1:0] row_addr = frame_base + ((out_row * FW + out_x0) >> 1);
    wire          slot_busy = (cslot_sync != pslot);

    always @(posedge clk_c) begin
        if (!rst_c_n) begin
            pcnt <= 4'd0; bidx <= 4'd0; pslot <= 1'b0;
            cslot_s1 <= 1'b0; cslot_s2 <= 1'b0;
            hdr_cnt <= 16'd0; drop_cnt <= 16'd0;
            addr_slot[0] <= {AW{1'b0}}; addr_slot[1] <= {AW{1'b0}};
            b0_0 <= {DW{1'b0}}; b0_1 <= {DW{1'b0}}; b0_2 <= {DW{1'b0}}; b0_3 <= {DW{1'b0}}; b0_4 <= {DW{1'b0}};
            b0_5 <= {DW{1'b0}}; b0_6 <= {DW{1'b0}}; b0_7 <= {DW{1'b0}}; b0_8 <= {DW{1'b0}}; b0_9 <= {DW{1'b0}};
            b1_0 <= {DW{1'b0}}; b1_1 <= {DW{1'b0}}; b1_2 <= {DW{1'b0}}; b1_3 <= {DW{1'b0}}; b1_4 <= {DW{1'b0}};
            b1_5 <= {DW{1'b0}}; b1_6 <= {DW{1'b0}}; b1_7 <= {DW{1'b0}}; b1_8 <= {DW{1'b0}}; b1_9 <= {DW{1'b0}};
        end else begin
            cslot_s1 <= cslot;
            cslot_s2 <= cslot_s1;

            if (de) begin
                // 直接落到目标 bank 的 16 位切片（不再经 acc）
                if (pslot == 1'b0) begin
                    case (bidx)
                    4'd0: b0_0[pcnt*16 +: 16] <= pix;
                    4'd1: b0_1[pcnt*16 +: 16] <= pix;
                    4'd2: b0_2[pcnt*16 +: 16] <= pix;
                    4'd3: b0_3[pcnt*16 +: 16] <= pix;
                    4'd4: b0_4[pcnt*16 +: 16] <= pix;
                    4'd5: b0_5[pcnt*16 +: 16] <= pix;
                    4'd6: b0_6[pcnt*16 +: 16] <= pix;
                    4'd7: b0_7[pcnt*16 +: 16] <= pix;
                    4'd8: b0_8[pcnt*16 +: 16] <= pix;
                    4'd9: b0_9[pcnt*16 +: 16] <= pix;
                    default: ;
                    endcase
                end else begin
                    case (bidx)
                    4'd0: b1_0[pcnt*16 +: 16] <= pix;
                    4'd1: b1_1[pcnt*16 +: 16] <= pix;
                    4'd2: b1_2[pcnt*16 +: 16] <= pix;
                    4'd3: b1_3[pcnt*16 +: 16] <= pix;
                    4'd4: b1_4[pcnt*16 +: 16] <= pix;
                    4'd5: b1_5[pcnt*16 +: 16] <= pix;
                    4'd6: b1_6[pcnt*16 +: 16] <= pix;
                    4'd7: b1_7[pcnt*16 +: 16] <= pix;
                    4'd8: b1_8[pcnt*16 +: 16] <= pix;
                    4'd9: b1_9[pcnt*16 +: 16] <= pix;
                    default: ;
                    endcase
                end
                if (pcnt == 4'd0) addr_slot[pslot] <= row_addr;
                if (pcnt == 4'd15) begin
                    pcnt <= 4'd0;
                    if (bidx == BEATS-1) begin
                        bidx <= 4'd0;
                        if (slot_busy) begin
                            drop_cnt <= drop_cnt + 16'd1;     // 来不及：丢这一行
                        end else begin
                            pslot    <= ~pslot;               // 发布
                            hdr_cnt  <= hdr_cnt + 16'd1;
                        end
                    end else bidx <= bidx + 4'd1;
                end else pcnt <= pcnt + 4'd1;
            end
        end
    end

    // ---------------- 读侧 clk_d ----------------
    reg  [1:0]    pslot_sync;
    reg  [3:0]    idx;              // 当前摆在 wdata 上的是本突发第几拍
    reg  [1:0]    st;
    localparam S_IDLE = 2'd0, S_AW = 2'd1, S_W = 2'd2;

    wire row_avail = (pslot_sync[1] != cslot);
    wire grant     = (st == S_AW) && awvalid && awready;   // AW 握手那一拍
    wire in_burst  = (st == S_W);
    wire consume   = wready && (in_burst || grant);        // wready 即"取走"

    assign wstrb  = {(DW/8){1'b1}};
    assign awid   = ID;
    assign wvalid = in_burst || grant;

    // 取 buffer 里的第 idx 拍：必须【在时序块里直接调用函数】，不能写成
    // wire slot_w = pick(...) —— ModelSim 对「连续赋值 + 函数」不会把函数内部读到的
    // 寄存器加进敏感表，b0_*/b1_* 变了 slot_w 也不更新，会一直停在 X。

    always @(posedge clk_d) begin
        if (!rst_d_n) begin
            pslot_sync <= 2'b00; cslot <= 1'b0; idx <= 4'd0;
            awvalid <= 1'b0; awaddr <= {AW{1'b0}}; awlen <= 4'd0;
            wdata <= {DW{1'b0}}; st <= S_IDLE; perr_cnt <= 16'd0;
        end else begin
            pslot_sync <= {pslot_sync[0], pslot};
            case (st)
            S_IDLE: begin
                awvalid <= 1'b0;
                if (row_avail) begin
                    // 第 0 拍必须在 AW 握手之前就摆好（IP 不看 wvalid）
                    awaddr <= addr_slot[cslot];
                    awlen  <= BEATS-1;
                    idx    <= 4'd0;
                    wdata  <= pick(cslot, idx);
                    st     <= S_AW;
                end
            end
            S_AW: begin
                if (!awvalid) begin
                    awvalid <= 1'b1;
                end else if (awready) begin
                    awvalid <= 1'b0;
                    st      <= S_W;
                    if (wready) begin          // 从设备在握手同拍就取走了第 0 拍
                        idx   <= 4'd1;
                        wdata <= pick(cslot, 4'd1);
                    end
                end
            end
            S_W: begin
                if (consume) begin
                    if (idx == BEATS-1 || wusero_last) begin
                        if (!(idx == BEATS-1 && wusero_last))
                            perr_cnt <= perr_cnt + 16'd1;   // 拍数与 wusero_last 对不上
                        cslot <= ~cslot;
                        idx   <= 4'd0;
                        st    <= S_IDLE;
                    end else begin
                        idx   <= idx + 4'd1;
                        wdata <= pick(cslot, idx + 4'd1);
                    end
                end
            end
            endcase
        end
    end
endmodule
