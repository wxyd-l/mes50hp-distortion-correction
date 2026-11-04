// ud_cdc_pulse.v -- 单拍脉冲跨时钟域（toggle + 三级同步，边沿检测）
// 用途：frame_start 从显示/采集域进到读核域，frame_done 反向出去。
// 约束：源域脉冲必须是【单拍】，且目标域时钟不低于源域的一半（本设计 42/50 MHz 满足）。
`timescale 1ns/1ps
module ud_cdc_pulse (
    input  wire clk_a,
    input  wire rst_a_n,
    input  wire pulse_a,       // 源域单拍脉冲
    input  wire clk_b,
    input  wire rst_b_n,
    output wire pulse_b        // 目标域单拍脉冲
);
    reg tog_a;
    always @(posedge clk_a) begin
        if (!rst_a_n) tog_a <= 1'b0;
        else if (pulse_a) tog_a <= ~tog_a;
    end

    reg [2:0] sync_b;
    always @(posedge clk_b) begin
        if (!rst_b_n) sync_b <= 3'b000;
        else          sync_b <= {sync_b[1:0], tog_a};
    end
    assign pulse_b = sync_b[2] ^ sync_b[1];
endmodule
