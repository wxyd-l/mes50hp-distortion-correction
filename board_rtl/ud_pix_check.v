// ud_pix_check.v -- 上板通路自检：数像素 + 求和，供 ILA / 寄存器读出对账
// 期望值来自仿真：pixels = 921600（一帧），sum 与仿真同一帧比对
`timescale 1ns/1ps

module ud_pix_check (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,        // 一拍清空（帧边界）
    input  wire        de,
    input  wire [15:0] pix,
    input  wire [11:0] x0,
    input  wire [11:0] row,
    output reg  [31:0] cnt,
    output reg  [31:0] sum32,
    output reg  [15:0] sum16,
    output reg  [11:0] last_row,
    output reg  [11:0] last_x0
);
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt <= 32'd0; sum32 <= 32'd0; sum16 <= 16'd0;
            last_row <= 12'd0; last_x0 <= 12'd0;
        end else if (clr) begin
            cnt <= 32'd0; sum32 <= 32'd0; sum16 <= 16'd0;
        end else if (de) begin
            cnt     <= cnt + 32'd1;
            sum32   <= sum32 + {16'd0, pix};
            sum16   <= sum16 + pix;
            last_row <= row;
            last_x0  <= x0;
        end
    end
endmodule
