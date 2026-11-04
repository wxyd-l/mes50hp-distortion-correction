// ud_axi_rd_arb.v -- 2:1 AXI 读通道仲裁（把 M4 的取数接到现有 fram_buf 的 AXI 读口上）
//
// 为什么需要：目标工程 hdmi_ddr_ov5640_top 里 fram_buf 直接驱动 DDR3 IP 的 AXI 读通道，
// 只有一路主设备。M4 要按 tile 读源行，必须和 fram_buf 分享这一路。
//
// 策略：【先排水，再整轮授出】
//   1) 被授权方只有在"本次授权后还没服务完任何突发"时才能连续受理 AR；
//      一旦服务完一个突发（served=1），只要对方开始请求就立刻关掉它的 arready（排水），
//      不让它再 refill。
//   2) 只有在"本方在飞突发数 oc 归零、且本拍没有受理新 AR"的那一拍才切 sel。
//      => 切换那一刻，本方【一定】没有任何突发挂在 DDR3 IP 的 AR 队列里，
//         所以 R 数据不会被错送给对方（板上画面污染就是这条不成立造成的）。
//   3) oc 必须把"同拍入队 + 同拍完成"算成净变化。旧版是两个 if 顺序赋值，
//      两者同时发生时会丢掉入队的那个 -> 仲裁器误判"空闲"、在仍有突发在飞时换主。
//
// en_b=0 时 B 路完全不请求，A 路是逐位直通（a_arready=arready / arvalid=a_arvalid /
// a_rvalid=rvalid），不引入任何额外时序负担 —— 对应板上已验证正常的 B 版。
`timescale 1ns/1ps

module ud_axi_rd_arb #(
    parameter integer AW = 28,
    parameter integer DW = 256,
    parameter integer LW = 4
) (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           en_b,        // 0 = 彻底关掉 B 路（M4）取数，A 路直通，画面不受任何影响

    // ---- 主设备 A：现有 fram_buf ----
    input  wire           a_arvalid,
    input  wire [AW-1:0]  a_araddr,
    input  wire [LW-1:0]  a_arlen,
    output wire           a_arready,
    output wire           a_rvalid,
    output wire [DW-1:0]  a_rdata,
    output wire           a_rlast,

    // ---- 主设备 B：M4 取数 ----
    input  wire           b_arvalid,
    input  wire [AW-1:0]  b_araddr,
    input  wire [LW-1:0]  b_arlen,
    output wire           b_arready,
    output wire           b_rvalid,
    output wire [DW-1:0]  b_rdata,
    output wire           b_rlast,

    // ---- 从设备：DDR3 IP ----
    output wire           arvalid,
    output wire [AW-1:0]  araddr,
    output wire [LW-1:0]  arlen,
    input  wire           arready,
    input  wire           rvalid,
    input  wire [DW-1:0]  rdata,
    input  wire           rlast
);
    localparam integer OCW = 3;                      // 在飞突发计数位宽（0..7，饱和）

    reg             sel;                             // 0 = A(fram_buf), 1 = B(M4)
    reg             served;                          // 本次授权后是否已服务完至少一个突发
    reg  [OCW-1:0]  oc_a, oc_b;                      // 未完成突发数

    wire a_go = a_arvalid && a_arready;
    wire b_go = b_arvalid && b_arready;
    wire a_rd = a_rvalid && a_rlast;
    wire b_rd = b_rvalid && b_rlast;

    wire            b_req    = b_arvalid && en_b;
    wire            sel_req  = sel ? b_req      : a_arvalid;   // 被授权方在请求
    wire            oth_req  = sel ? a_arvalid  : b_req;       // 另一方在请求
    wire [OCW-1:0]  sel_oc   = sel ? oc_b       : oc_a;
    wire            sel_go   = sel ? b_go       : a_go;
    wire            sel_rd   = sel ? b_rd       : a_rd;
    wire            sel_busy = (sel_oc != {OCW{1'b0}});

    // 已服务过的被授权方，一旦对方开始请求就不再受理新 AR（排水）；
    // 刚被授权、还没服务完任何突发的一方可以先把请求发出去，否则授权了也发不出去。
    wire allow = !(served && oth_req);

    // 换主条件：对方在请求 + 本方码空 + 本拍没受理新 AR + 已经服务过（或本方已不再请求）
    wire handover = oth_req && !sel_busy && !sel_go && (served || !sel_req);

    always @(posedge clk) begin
        if (!rst_n) begin
            sel    <= 1'b0;
            served <= 1'b0;
            oc_a   <= {OCW{1'b0}};
            oc_b   <= {OCW{1'b0}};
        end else begin
            // 同拍入队与同拍完成取净变化：2'b11 表示进出一个，计数不变
            case ({a_go, a_rd})
                2'b10:   if (oc_a != {OCW{1'b1}}) oc_a <= oc_a + 1'b1;
                2'b01:   if (oc_a != {OCW{1'b0}}) oc_a <= oc_a - 1'b1;
                default: ;                        // 00 不变；11 净 0
            endcase
            case ({b_go, b_rd})
                2'b10:   if (oc_b != {OCW{1'b1}}) oc_b <= oc_b + 1'b1;
                2'b01:   if (oc_b != {OCW{1'b0}}) oc_b <= oc_b - 1'b1;
                default: ;                        // 00 不变；11 净 0
            endcase

            if (sel_rd) served <= 1'b1;            // 本方已经拿到过一个突发
            if (handover) begin                    // 排水完成才换主（同拍时以换主为准）
                sel    <= ~sel;
                served <= 1'b0;                    // 新一轮授权重新开始
            end
        end
    end

    // 注意：allow=0 时【必须连 arvalid 一起压掉】。只压主设备侧的 arready 是不够的：
    // IP 那一侧看到的是 arvalid=1、arready=1，它会把这个 AR 收进队列，而主设备却以为
    // 没发出去（a_go=0 不计数）—— 于是仲裁器完全不知道路上多了一个突发，换主时 R 数据错送。
    assign arvalid   = (sel ? b_arvalid : a_arvalid) && allow;
    assign araddr    = sel ? b_araddr  : a_araddr;
    assign arlen     = sel ? b_arlen   : a_arlen;

    assign a_arready = !sel && allow && arready;
    assign b_arready =  sel && allow && arready;

    assign a_rvalid  = !sel && rvalid;
    assign b_rvalid  =  sel && rvalid;
    assign a_rdata   = rdata;
    assign b_rdata   = rdata;
    assign a_rlast   = rlast;
    assign b_rlast   = rlast;
endmodule
