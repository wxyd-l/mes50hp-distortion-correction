// =============================================================================
//  ud_win_tab.v -- 窗口基准表（M3b）：断点 ROM + 线性插值
//
//  每个 tile 有 SEG+1 = 181 个断点（每 4 行一个），覆盖 0..719。
//  地址 = tile*STRIDE + (row>>HLOG)；row 的低 HLOG 位是段内小数。
//  输出 = v0 + ((v1 - v0) * frac) >>> HLOG     （算术右移 = 向下取整，与模型一致）
//
//  时延 2 拍：v0/v1/frac 寄存一次，插值结果再寄存一次。
//  表内容由 tools/m3_model.mjs --emit-tab 生成（wintab_lo.hex / wintab_base.hex），
//  与模型 buildWinTab() 完全同源；上板时可用 wr_* 口在帧边界整体改写。
// =============================================================================
`timescale 1ns/1ps

module ud_win_tab #(
    parameter integer TBITS  = 12,
    parameter integer TILES  = 8,
    parameter integer HLOG   = 2,
    parameter integer SEG    = (720 >> HLOG),
    parameter integer STRIDE = SEG + 1,
    parameter [8*40-1:0] TABFILE = "wintab_lo.hex"
) (
    input  wire                 clk,
    input  wire [2:0]           tile,
    input  wire [11:0]          row,
    output reg  signed [TBITS:0] val,
    input  wire                 wr_en,
    input  wire [11:0]          wr_addr,
    input  wire [TBITS-1:0]     wr_data
);
    reg [TBITS-1:0] tab [0:TILES*STRIDE-1];

    // 仿真与综合都用同一个 hex 预置（文件相对 vsim 的工作目录）
    initial $readmemh(TABFILE, tab);

    wire [10:0] k   = row >> HLOG;
    wire [11:0] a0  = tile * STRIDE + k;

    reg signed [TBITS:0]   v0_s;
    reg signed [TBITS:0]   d_r;
    reg        [HLOG-1:0]  frac_r;

    always @(posedge clk) begin
        if (wr_en) tab[wr_addr[11:0]] <= wr_data;
        v0_s   <= $signed({1'b0, tab[a0]});
        d_r    <= $signed({1'b0, tab[a0 + 1'b1]}) - $signed({1'b0, tab[a0]});
        frac_r <= row[HLOG-1:0];
    end

    wire signed [TBITS+HLOG:0] prod = d_r * $signed({1'b0, frac_r});
    wire signed [TBITS+HLOG:0] quot = prod >>> HLOG;

    always @(posedge clk) val <= v0_s + $signed(quot[TBITS:0]);

endmodule
