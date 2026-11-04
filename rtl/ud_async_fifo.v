// ud_async_fifo.v -- 格雷码指针异步 FIFO（标准结构，两个时钟完全无关）
// 用途：DDR 读回字流（32 bit/字）从 DDR 域搬到读核域。
// 约束：写侧只在 !wfull 时写、读侧只在 !rempty 时读；指针格雷码跨域前各打两拍。
`timescale 1ns/1ps
module ud_async_fifo #(
    parameter integer DW = 32,
    parameter integer AW = 8            // 深度 = 2^AW
) (
    input  wire          wclk,
    input  wire          wrst_n,
    input  wire          wen,
    input  wire [DW-1:0] wdata,
    output wire          wfull,
    input  wire          rclk,
    input  wire          rrst_n,
    input  wire          ren,
    output wire [DW-1:0] rdata,
    output wire          rempty
);
    localparam integer DEPTH = 1 << AW;
    reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wbin, wgray, rbin, rgray;
    reg  [AW:0] rgray_s1, rgray_s2, wgray_s1, wgray_s2;

    // 注意：winc 与 wfull 必须【不互相依赖】——旧写法用 wgray_nx 判满、
    // 又用 wfull 门控 wbin_nx，形成组合环，仿真直接变 X。这里用当前寄存指针判满。
    wire        winc = wen && !wfull;
    wire        rinc = ren && !rempty;
    wire [AW:0] wbin_nx = wbin + winc;
    wire [AW:0] rbin_nx = rbin + rinc;
    wire [AW:0] wgray_nx = (wbin_nx >> 1) ^ wbin_nx;
    wire [AW:0] rgray_nx = (rbin_nx >> 1) ^ rbin_nx;

    always @(posedge wclk) begin
        if (!wrst_n) begin
            wbin <= 0; wgray <= 0; rgray_s1 <= 0; rgray_s2 <= 0;
        end else begin
            wbin <= wbin_nx; wgray <= wgray_nx;
            rgray_s1 <= rgray; rgray_s2 <= rgray_s1;
        end
    end

    always @(posedge rclk) begin
        if (!rrst_n) begin
            rbin <= 0; rgray <= 0; wgray_s1 <= 0; wgray_s2 <= 0;
        end else begin
            rbin <= rbin_nx; rgray <= rgray_nx;
            wgray_s1 <= wgray; wgray_s2 <= wgray_s1;
        end
    end

    always @(posedge wclk) if (winc) mem[wbin[AW-1:0]] <= wdata;

    assign rdata  = mem[rbin[AW-1:0]];
    // 满：写指针下一拍的高两位取反后与读指针同步值相同
    assign wfull  = (wgray == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    assign rempty = (rgray == wgray_s2);
endmodule
