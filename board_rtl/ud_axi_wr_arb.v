// ud_axi_wr_arb.v -- 2:1 AXI 写通道仲裁（fram_buf 采集写入 与 M4 写主 共享 DDR3 写口）
//
// 目标 IP 的写通道不是标准 AXI（见 ud_axi_wr_master.v 头注释）：没有 wvalid/wlast 输入，
// 只有 wready 和 wusero_last/wusero_id 两个输出。所以这里：
//   * 计数【只看 wready】—— wready 为高就是被取走一拍，与 master 的 wvalid 无关；
//   * 突发结束以从设备的 wusero_last 为准，awlen+1 当自检（不一致计 perr_cnt）；
//   * 授权只在空闲或突发结束那一拍切换，所以 wdata/wstrb 不会在突发中间被换主；
//   * wusero_last 路由回当前被授权的那一方。
//
// 为什么不需要用 wusero_id 做路由：同一时刻只有一个 client 的突发在飞（整突发授权），
// wusero_id 在物理上必然等于当前 sel 对应的 awid。真接进工程后可以用它做白盒断言。
`timescale 1ns/1ps

module ud_axi_wr_arb #(
    parameter integer AW = 28,
    parameter integer DW = 256
) (
    input  wire           clk,
    input  wire           rst_n,

    // ---- 主设备 A：fram_buf（采集写入）
    input  wire           a_awvalid,
    input  wire [AW-1:0]  a_awaddr,
    input  wire [3:0]     a_awlen,
    input  wire [3:0]     a_awid,
    output wire           a_awready,
    input  wire           a_wvalid,
    input  wire [DW-1:0]  a_wdata,
    input  wire [DW/8-1:0] a_wstrb,
    output wire           a_wready,
    output wire           a_wusero_last,

    // ---- 主设备 B：M4 写主
    input  wire           b_awvalid,
    input  wire [AW-1:0]  b_awaddr,
    input  wire [3:0]     b_awlen,
    input  wire [3:0]     b_awid,
    output wire           b_awready,
    input  wire           b_wvalid,
    input  wire [DW-1:0]  b_wdata,
    input  wire [DW/8-1:0] b_wstrb,
    output wire           b_wready,
    output wire           b_wusero_last,

    // ---- 从设备：DDR3 IP
    output wire           awvalid,
    output wire [AW-1:0]  awaddr,
    output wire [3:0]     awlen,
    output wire [3:0]     awid,
    input  wire           awready,
    output wire           wvalid,
    output wire [DW-1:0]  wdata,
    output wire [DW/8-1:0] wstrb,
    input  wire           wready,
    input  wire           wusero_last
);
    reg        sel;         // 0 = A(fram_buf), 1 = B(M4)
    reg  [4:0] beats;       // 本突发还剩几拍（0 = 空闲）
    reg [15:0] perr_cnt;    // 拍数与 wusero_last 不一致的次数（白盒观察用）

    wire        active     = (beats != 5'd0);
    wire        sel_awv    = sel ? b_awvalid : a_awvalid;
    wire [3:0]  sel_awlen  = sel ? b_awlen   : a_awlen;
    wire        aw_req     = !active && sel_awv;
    wire        aw_accept  = aw_req && awready;
    wire        consume    = wready && (active || aw_accept);
    wire [4:0]  nxt        = aw_accept ? ({1'b0, sel_awlen} + 5'd1) : beats;
    wire        done_now   = consume && (wusero_last || (nxt == 5'd1));
    wire        oth_aw_req = sel ? a_awvalid : b_awvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            sel <= 1'b0; beats <= 5'd0; perr_cnt <= 16'd0;
        end else begin
            if (done_now) begin
                if (!(wusero_last && (nxt == 5'd1)))
                    perr_cnt <= perr_cnt + 16'd1;
                beats <= 5'd0;
            end else if (aw_accept) begin
                beats <= wready ? ({1'b0, sel_awlen}) : ({1'b0, sel_awlen} + 5'd1);
            end else if (consume && active) begin
                beats <= beats - 5'd1;
            end

            if (done_now)
                sel <= oth_aw_req ? ~sel : sel;
            else if (!active && !aw_accept && oth_aw_req)
                sel <= ~sel;
        end
    end

    assign awvalid = aw_req;
    assign awaddr  = sel ? b_awaddr : a_awaddr;
    assign awlen   = sel ? b_awlen  : a_awlen;
    assign awid    = sel ? b_awid   : a_awid;
    assign a_awready = !sel && !active && awready;
    assign b_awready =  sel && !active && awready;

    // wvalid 只给标准 AXI 风格的 TB 用；真 IP 不看它
    assign wvalid  = active || aw_accept;
    assign wdata   = sel ? b_wdata : a_wdata;
    assign wstrb   = sel ? b_wstrb : a_wstrb;
    assign a_wready = !sel && wready && (active || aw_accept);
    assign b_wready =  sel && wready && (active || aw_accept);

    assign a_wusero_last = !sel && wusero_last;
    assign b_wusero_last =  sel && wusero_last;
endmodule
