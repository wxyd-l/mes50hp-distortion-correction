// tb_m4_arb_sys.v -- stage 1 板级拓扑仿真：M4 读链 + 【读仲裁】 + 一路抢带宽的显示读
//
// 为什么需要：tb_m4_dual 只有 M4 一个读主（ar_ready 恒 1），测不出"两路抢同一路 AXI 读"
// 会不会把 M4 的数据搞坏 —— 这正是上板要验的事。这里把 ud_axi_rd_arb 插进去，
// 再加一个 rd_ctrl 同款的 A 主（只等 arready、不看 rlast、每 16 拍续一个 AR），
// 看 M4 的输出是不是仍然逐位对得上黄金模型。
//
// 判据（三条）：
//   1) 与 m3_model 对拍：unequal 0 / 921600
//   2) 每拍 R 数据的属主必须等于仲裁器当前的 sel（白盒断言，直接查"错送"）
//   3) 两路都要有进展（A 不能饿死 B，B 也不能饿死 A）
`timescale 1ns/1ps

module tb_m4_arb_sys;
    localparam integer TW = 160, SW = 256, H = 720, FW = 1280;
    localparam integer RPB = 120;
    localparam integer AW = 28, DW = 256, LW = 4;
    localparam integer QD = 4;               // DDR 侧 AR 队列深度
    localparam [3:0] QD4 = QD;

    parameter integer NT  = 8;
    parameter integer K1Q = 0;
    parameter integer MG  = 8;
    parameter integer A00 = 357914,  A01 = 0,       A02 = -228885965;
    parameter integer A10 = 0,       A11 = 357914,  A12 = -128670062;
    parameter integer H20 = 0, H21 = 0, W0 = 16777216;
    parameter integer LATF = 29;
    parameter real    CLKP = 10.0;      // 核心域半周期 ns（10 = 100 MHz）
    parameter real    DDRP = 11.9045;   // DDR 域半周期 ns
    parameter integer DLY  = 12;        // DDR 读延迟（拍）
    parameter integer ALEN = 15;        // A 主每突发拍数-1（16 拍 = 512 B）
    parameter integer AGAP = 0;         // A 主受理后空闲拍数（0 = 最贪婪）
    parameter integer WDOG = 0;
    parameter integer STPRD = 0;
    parameter integer UX = 65536, UV = 0, U0 = 0;
    parameter integer IV = 65536;
    parameter integer VX = 0, VV = 65536, V0 = 0;

    localparam [3:0] A_LEN4 = ALEN;
    localparam [3:0] DLY4   = DLY;

    reg clk = 0, clk_ddr = 0, rst_n = 0;
    always #CLKP  clk     = ~clk;
    always #DDRP  clk_ddr = ~clk_ddr;

    reg frame_start = 0;
    wire start_o, frame_done, tile_done;
    wire [11:0] row_v, tile_x0;
    wire [3:0] tile_idx;

    ud_tile_sched #(.TW(TW), .HEIGHT(H), .NT(NT)) sched (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .tile_done(tile_done),
        .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .tile_idx(tile_idx), .frame_done(frame_done)
    );

    wire de_o; wire [15:0] data_o;
    wire fd_req; wire [11:0] fd_row; wire [11:0] fd_x0;
    wire fd_ack; wire [31:0] fd_data; wire fd_data_vld;
    wire fd_abort, fd_pop;

    // ---------------- M4 读链（与上板同一条：核心 -> CDC -> AXI 读口）----------------
    wire        m4_arvalid;
    wire [AW-1:0] m4_araddr;
    wire [LW-1:0] m4_arlen;
    wire        m4_arready;
    wire        m4_rvalid, m4_rlast;
    wire [DW-1:0] m4_rdata;

    ud_row_rd_cdc #(.TW(SW), .FW(FW), .AW(8)) u_rd (
        .clk_c(clk), .rst_c_n(rst_n),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0),
        .fd_abort(fd_abort), .fd_pop(fd_pop),
        .fd_ack(fd_ack), .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .clk_d(clk_ddr), .rst_d_n(rst_n), .page(2'd0),
        .ar_valid(m4_arvalid), .ar_addr(m4_araddr), .ar_len(m4_arlen), .ar_ready(m4_arready),
        .r_data(m4_rdata), .r_valid(m4_rvalid), .r_last(m4_rlast)
    );

    // ---------------- A 主：rd_ctrl 同款（只等 arready，不看 rlast）----------------
    reg        a_arvalid = 0;
    reg [AW-1:0] a_araddr = 0;
    wire       a_arready;
    wire       a_rvalid, a_rlast;
    wire [DW-1:0] a_rdata;

    reg  [1:0]  a_st = 0;              // 0=IDLE 1=AR 2=END
    reg  [15:0] a_cnt = 0;
    reg  [27:0] a_line = 0;
    integer a_bursts = 0, a_beats = 0;
    assign a_arvalid = (a_st == 2'd1);

    always @(posedge clk_ddr) begin
        if (!rst_n) begin
            a_st <= 0; a_cnt <= 0; a_arvalid <= 0; a_line <= 0;
        end else begin
            case (a_st)
            2'd0: begin
                a_arvalid <= 1'b1;
                a_st  <= 2'd1;
            end
            2'd1: begin
                if (a_arvalid && a_arready) begin
                    a_arvalid <= 1'b0;
                    a_cnt <= 0;
                    a_st  <= 2'd2;
                    a_line <= a_line + 28'd640;      // 下一条源行（1280 px = 640 字）
                end
            end
            default: begin
                if (a_cnt == AGAP) a_st <= 2'd0; else a_cnt <= a_cnt + 16'd1;
            end
            endcase
        end
    end
    assign a_araddr = a_line;                        // 地址内容对 A 不重要
    always @(posedge clk_ddr) if (rst_n) begin
        if (a_arvalid && a_arready)         a_bursts = a_bursts + 1;
        if (a_rvalid)                       a_beats  = a_beats + 1;
    end

    // ---------------- 读仲裁 ----------------
    wire        axi_arvalid, axi_arready, axi_rvalid, axi_rlast;
    wire [AW-1:0] axi_araddr;
    wire [LW-1:0] axi_arlen;
    wire [DW-1:0] axi_rdata;

    ud_axi_rd_arb #(.AW(AW), .DW(DW), .LW(LW)) u_arb (
        .clk(clk_ddr), .rst_n(rst_n), .en_b(1'b1),
        .a_arvalid(a_arvalid), .a_araddr(a_araddr), .a_arlen(A_LEN4), .a_arready(a_arready),
        .a_rvalid(a_rvalid), .a_rdata(a_rdata), .a_rlast(a_rlast),
        .b_arvalid(m4_arvalid), .b_araddr(m4_araddr), .b_arlen(m4_arlen), .b_arready(m4_arready),
        .b_rvalid(m4_rvalid), .b_rdata(m4_rdata), .b_rlast(m4_rlast),
        .arvalid(axi_arvalid), .araddr(axi_araddr), .arlen(axi_arlen), .arready(axi_arready),
        .rvalid(axi_rvalid), .rdata(axi_rdata), .rlast(axi_rlast)
    );

    // ---------------- DDR 从设备：AR 队列 + 延迟 + 逐拍回数 ----------------
    function [15:0] src;
        input integer r, c;
        begin
            src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31);
        end
    endfunction

    reg [AW-1:0] q_addr [0:QD-1];
    reg [LW-1:0] q_len  [0:QD-1];
    reg          q_who  [0:QD-1];
    reg [1:0]    q_wr = 0, q_rd = 0;   // 2 位指针，模 4 自然回绕（3 位会越界读出 X）
    reg [3:0]    q_cnt = 0;

    reg [AW-1:0] lat_addr = 0;
    reg [LW-1:0] lat_len  = 0;
    reg          lat_who  = 0;
    reg [1:0]    st = 0;
    reg [3:0]    cnt = 0;
    reg [4:0]    b = 0;
    reg [255:0]  beat = 0;
    reg          rvalid_r = 0, rlast_r = 0;
    reg [DW-1:0] rdata_q = 0;

    assign axi_arready = (q_cnt < QD4);
    assign axi_rvalid  = rvalid_r;
    assign axi_rlast   = rlast_r;
    assign axi_rdata   = rdata_q;

    wire enq = axi_arvalid && axi_arready;
    wire deq = (st == 2'd0) && (q_cnt != 4'd0);

    integer k2, rr, x0i, jj;

    always @(posedge clk_ddr) begin
        if (!rst_n) begin
            q_wr <= 0; q_rd <= 0; q_cnt <= 0; st <= 0; cnt <= 0; b <= 0;
            rvalid_r <= 0; rlast_r <= 0; rdata_q <= 0; lat_addr <= 0; lat_len <= 0; lat_who <= 0;
        end else begin
            if (enq) begin
                q_addr[q_wr] <= axi_araddr;
                q_len [q_wr] <= axi_arlen;
                q_who [q_wr] <= u_arb.sel;      // 属主 = 仲裁器当前授权方
                q_wr <= q_wr + 2'd1;
            end
            q_cnt <= q_cnt + (enq ? 4'd1 : 4'd0) - (deq ? 4'd1 : 4'd0);

            case (st)
            // 注意：这两个状态必须把 rvalid/rlast 拉低。否则上一突发的最后一个
            // rlast 会在等待期一直挂着 -> 仲裁器看到重复 rlast -> oc 提前归零 ->
            // 换主时仍有突发在飞 -> 真数据错送（本 TB 踩过这个坑）。
            2'd0: begin
                      rvalid_r <= 1'b0; rlast_r <= 1'b0;
                      if (q_cnt != 4'd0) begin
                          lat_addr <= q_addr[q_rd];
                          lat_len  <= q_len[q_rd];
                          lat_who  <= q_who[q_rd];
                          q_rd <= q_rd + 2'd1;
                          cnt  <= DLY4;
                          b    <= 0;
                          st   <= 2'd1;
                      end
                  end
            2'd1: begin
                      rvalid_r <= 1'b0; rlast_r <= 1'b0;
                      if (cnt != 4'd0) cnt <= cnt - 4'd1;
                      else             st  <= 2'd2;
                  end
            default: begin
                      if (lat_who == 1'b1) begin
                          rr  = lat_addr / (FW/2);
                          x0i = (lat_addr % (FW/2)) * 2;
                          for (k2 = 0; k2 < 8; k2 = k2 + 1) begin
                              jj = b*8 + k2;
                              beat[k2*32 +: 32] = { src(rr, x0i + 2*jj + 1), src(rr, x0i + 2*jj) };
                          end
                          rdata_q <= beat;
                      end else begin
                          rdata_q <= {32{8'hA5}};   // A 路的数据内容不参与比对
                      end
                      rvalid_r <= 1'b1;
                      rlast_r  <= (b == {1'b0, lat_len});
                      if (b == {1'b0, lat_len}) st <= 2'd0;
                      else                   b  <= b + 5'd1;
                  end
            endcase
        end
    end

    // 换主那一拍，旧授权方必须已经码空
    reg sel_q = 1'b0;
    integer n_bad_switch = 0;
    always @(negedge clk_ddr) if (rst_n) begin
        if (u_arb.sel !== sel_q) begin
            if (sel_q === 1'b0 && u_arb.oc_a !== 3'd0) begin
                if (n_bad_switch < 5) $display("ERR switch A->B while oc_a=%0d @%0t", u_arb.oc_a, $time);
                n_bad_switch = n_bad_switch + 1;
            end
            if (sel_q === 1'b1 && u_arb.oc_b !== 3'd0) begin
                if (n_bad_switch < 5) $display("ERR switch B->A while oc_b=%0d @%0t", u_arb.oc_b, $time);
                n_bad_switch = n_bad_switch + 1;
            end
            sel_q = u_arb.sel;
        end
    end

    // R 数据属主必须等于仲裁器当前 sel（错送会直接抓出来）
    integer misroute = 0;
    always @(posedge clk_ddr) if (rst_n && rvalid_r) begin
        if (lat_who !== u_arb.sel) begin
            if (misroute < 5) $display("ERR misroute @%0t: beat owner=%b but sel=%b", $time, lat_who, u_arb.sel);
            misroute = misroute + 1;
        end
    end

    // ---------------- 被测核 ----------------
    wire [11:0] core_row, core_x0;   // 核心给出的、与 de_o 同拍的行号/列条号
    ud_tile_core_m4 #(
        .TW(TW), .SW(SW), .HEIGHT(H), .RPB(RPB), .WINHLOG(1), .MARGIN(MG),
        .K1CFG(K1Q), .LATF(LATF), .LAG(49),
        .P_IV(IV), .P_VX(VX), .P_VV(VV), .P_V0(V0),
        .P_A00(A00), .P_A01(A01), .P_A02(A02),
        .P_A10(A10), .P_A11(A11), .P_A12(A12),
        .P_H20(H20), .P_H21(H21), .P_W0(W0),
        .P_K1(K1Q)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .fd_abort(fd_abort), .fd_pop(fd_pop),
        .cfg_ux(UX), .cfg_uv(UV), .cfg_u0(U0),
        .cfg_a00(A00), .cfg_a01(A01), .cfg_a02(A02),
        .cfg_a10(A10), .cfg_a11(A11), .cfg_a12(A12),
        .cfg_h20(H20), .cfg_h21(H21), .cfg_w0(W0),
        .de_o(de_o), .data_o(data_o), .row_done(tile_done),
        .out_row(core_row), .out_x0(core_x0)
    );

    // 归属：行号/列条号一律取核心输出（与 de_o 同拍，见上面的实例端口）。
    // 行间流水后 start_o 与像素不再对齐，靠 start_o 复位 cc 会把整帧记到错误的行上
    // （实测 unequal 921458/921600 全是假失败）。
    integer fd, tot, cc, curv, curx, i, seen_cnt;
    reg seen [0:8*160*720-1];
    always @(posedge clk) begin
        if (de_o) begin
            seen[core_row*8*160 + core_x0 + cc] = 1'b1;
            if (K1Q != 0) $fdisplay(fd, "%0d %0d %h", core_row, core_x0 + cc, data_o);
            tot = tot + 1;
            cc = (cc == 159) ? 0 : cc + 1;
        end
    end

    integer n_abort = 0, n_abort_busy = 0;
    always @(posedge clk) if (rst_n && dut.ld_vtop) begin
        n_abort = n_abort + 1;
        if (dut.f_busy) n_abort_busy = n_abort_busy + 1;
    end

    integer cyc = 0;
    always @(posedge clk) if (rst_n) cyc = cyc + 1;

    integer n_burst_b = 0;
    always @(posedge clk_ddr) if (rst_n && m4_arvalid && m4_arready) n_burst_b = n_burst_b + 1;

    integer last_print = 0;
    always @(posedge clk) if (rst_n && STPRD > 0 && ($time - last_print) >= STPRD) begin
        last_print = $time;
        $display("T=%0t st=%0d f_busy=%0d f_wait=%0d tot=%0d a_bursts=%0d b_bursts=%0d mis=%0d",
                 $time, dut.st, dut.f_busy, dut.f_wait, tot, a_bursts, n_burst_b, misroute);
    end

    initial begin
        if (WDOG > 0) begin
            #(WDOG);
            $display("WATCHDOG t=%0t pixels=%0d st=%0d f_busy=%0d f_wait=%0d a_bursts=%0d b_bursts=%0d mis=%0d",
                     $time, tot, dut.st, dut.f_busy, dut.f_wait, a_bursts, n_burst_b, misroute);
            $finish;
        end
    end

    reg [8*128-1:0] dump_name;
    initial begin
        tot = 0; cc = 0; curv = 0; curx = 0; seen_cnt = 0;
        for (i = 0; i < 8*160*720; i = i + 1) seen[i] = 1'b0;
        if (!$value$plusargs("DUMP=%s", dump_name)) dump_name = "rtl_arbsys.txt";
        fd = $fopen(dump_name, "w");
        if (fd == 0) begin $display("DUMPOPEN_FAIL %0s", dump_name); $finish; end
        $display("DUMPFILE %0s", dump_name);
        #20 rst_n = 1; @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        #2000;   // 行间流水后 row_done 比本行最后一个像素早 LAG+3 拍，200 ns(=20 拍) 会截掉行尾
        for (i = 0; i < 8*160*720; i = i + 1) if (!seen[i]) seen_cnt = seen_cnt + 1;
        $display("ARBSYS tiles=%0d K1Q=%0d pixels=%0d holes=%0d aborts=%0d (busy=%0d) cyc=%0d a_bursts=%0d a_beats=%0d b_bursts=%0d misroute=%0d badsw=%0d %s",
                 NT, K1Q, tot, seen_cnt, n_abort, n_abort_busy, cyc, a_bursts, a_beats, n_burst_b, misroute, n_bad_switch,
                 (misroute == 0 && n_bad_switch == 0) ? "ROUTE_OK" : "ROUTE_BAD");
        $fclose(fd);
        $finish;
    end
endmodule
