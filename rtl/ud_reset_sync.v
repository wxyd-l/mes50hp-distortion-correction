// ud_reset_sync.v -- 复位同步：异步置位、同步释放（每个时钟域各一个）
// 上板时外部 rst_n 与两个时钟域都异步，直接接到两边的触发器上会造成
// 同一周期内不同域退出复位的时刻不确定。这里按域各自同步释放。
`timescale 1ns/1ps

module ud_reset_sync (
    input  wire clk,
    input  wire arst_n,     // 异步复位输入（低有效）
    output wire srst_n      // 同步释放后的复位（低有效）
);
    reg [1:0] sync;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) sync <= 2'b00;
        else         sync <= {sync[0], 1'b1};
    end
    assign srst_n = sync[1];
endmodule
