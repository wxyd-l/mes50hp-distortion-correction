// tb_m4_dual.v -- 板级拓扑整链路仿真：核心域 + async FIFO + DDR 域，两个独立时钟
// 与 tb_ud_bil_m4_dump 的区别：读回路径走 ud_row_rd_cdc（上板用的那条），不是直连。
`timescale 1ns/1ps

module tb_m4_dual;
    localparam integer TW = 160, SW = 256, H = 720, FW = 1280;
    localparam integer RPB = 120;

    parameter integer NT  = 8;
    parameter integer K1Q = 0;
    parameter integer MG  = 8;
    parameter integer A00 = 357914,  A01 = 0,       A02 = -228885965;
    parameter integer A10 = 0,       A11 = 357914,  A12 = -128670062;
    parameter integer H20 = 0, H21 = 0, W0 = 16777216;
    parameter integer LATF = 29;
    parameter real    CLKP = 10.0;      // 核心域半周期 ns（10 = 50 MHz）
    parameter real    DDRP = 11.9045;   // DDR 域半周期 ns（42 MHz）
    parameter integer DLY  = 12;
    parameter integer WDOG = 0;      // >0: 到该 ns 强制结束并打印状态
    parameter integer STPRD = 0;     // >0: 每该 ns 打印一次状态
    parameter integer UX = 65536, UV = 0, U0 = 0;
    parameter integer IV = 65536;
    parameter integer VX = 0, VV = 65536, V0 = 0;

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
    wire ar_valid; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg  ar_ready = 1; reg [255:0] r_data = 0; reg r_valid = 0; reg r_last = 0;

    // 板级拓扑：核心 <-> cdc <-> ddr 引擎
    ud_row_rd_cdc #(.TW(SW), .FW(FW), .AW(8)) u_rd (
        .clk_c(clk), .rst_c_n(rst_n),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0),
        .fd_ack(fd_ack), .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .fd_abort(fd_abort), .fd_pop(fd_pop),
        .clk_d(clk_ddr), .rst_d_n(rst_n), .page(2'd0),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

    // DDR 行为模型（跑在 clk_ddr 域）
    function [15:0] src;
        input integer r, c;
        begin
            src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31);
        end
    endfunction

    reg [27:0] a_addr; reg [3:0] a_len;
    integer cnt, b, rr, x0i, jj, k2;
    reg [255:0] beat;
    always @(posedge clk_ddr) begin
        if (!rst_n) begin r_valid <= 0; r_last <= 0; cnt <= 0; b <= 0; end
        else begin
            if (ar_valid && ar_ready) begin
                a_addr <= ar_addr; a_len <= ar_len; cnt <= DLY; b <= 0; r_valid <= 0;
            end else if (cnt > 0) begin
                cnt <= cnt - 1;
                if (cnt == 1) b <= 0;
            end else if (b <= a_len) begin
                rr  = a_addr / (FW/2);
                x0i = (a_addr % (FW/2)) * 2;
                for (k2 = 0; k2 < 8; k2 = k2 + 1) begin
                    jj = b*8 + k2;
                    beat[k2*32 +: 32] = { src(rr, x0i + 2*jj + 1), src(rr, x0i + 2*jj) };
                end
                r_data <= beat; r_valid <= 1'b1; r_last <= (b == a_len); b <= b + 1;
            end else begin
                r_valid <= 1'b0; r_last <= 1'b0;
            end
        end
    end

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

    // 探针：abort 与 FIFO 残字
    integer n_abort = 0, n_abort_busy = 0;
    always @(posedge clk) if (rst_n && dut.ld_vtop) begin
        n_abort = n_abort + 1;
        if (dut.f_busy) n_abort_busy = n_abort_busy + 1;
    end

    integer cyc = 0;
    always @(posedge clk) if (rst_n) cyc = cyc + 1;

    integer n_fdreq = 0, n_burst = 0, n_words_out = 0;
    always @(posedge clk)     if (rst_n && fd_req)      n_fdreq   = n_fdreq + 1;
    always @(posedge clk_ddr) if (rst_n && ar_valid && ar_ready) n_burst = n_burst + 1;
    always @(posedge clk)     if (rst_n && fd_data_vld) n_words_out = n_words_out + 1;

    integer last_print = 0;
    always @(posedge clk) if (rst_n && STPRD > 0 && ($time - last_print) >= STPRD) begin
        last_print = $time;
        $display("T=%0t st=%0d f_busy=%0d f_wait=%0d f_col=%0d vtop=%0d need_top=%0d base=%0d dvld=%b avail=%b oust=%b tot=%0d fdreq=%0d burst=%0d words=%0d",
                 $time, dut.st, dut.f_busy, dut.f_wait, dut.f_col, dut.vtop, dut.need_top, dut.base,
                 fd_data_vld, (u_rd.avail != 0), u_rd.outstanding, tot, n_fdreq, n_burst, n_words_out);
    end
    initial begin
        if (WDOG > 0) begin
            #(WDOG);
            $display("WATCHDOG t=%0t pixels=%0d st=%0d f_busy=%0d f_wait=%0d f_col=%0d vtop=%0d need_top=%0d base=%0d",
                     $time, tot, dut.st, dut.f_busy, dut.f_wait, dut.f_col, dut.vtop, dut.need_top, dut.base);
            $finish;
        end
    end

    reg [8*128-1:0] dump_name;
    initial begin
        tot = 0; cc = 0; curv = 0; curx = 0; seen_cnt = 0;
        for (i = 0; i < 8*160*720; i = i + 1) seen[i] = 1'b0;
        if (!$value$plusargs("DUMP=%s", dump_name)) dump_name = "rtl_dual.txt";
        fd = $fopen(dump_name, "w");
        if (fd == 0) begin $display("DUMPOPEN_FAIL %0s", dump_name); $finish; end
        $display("DUMPFILE %0s", dump_name);
        #20 rst_n = 1; @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        #2000;   // 行间流水后 row_done 比本行最后一个像素早 LAG+3 拍，200 ns(=20 拍) 会截掉行尾
        for (i = 0; i < 8*160*720; i = i + 1) if (!seen[i]) seen_cnt = seen_cnt + 1;
        $display("DUALM4 tiles=%0d K1Q=%0d pixels=%0d holes=%0d aborts=%0d (busy=%0d) cyc=%0d",
                 NT, K1Q, tot, seen_cnt, n_abort, n_abort_busy, cyc);
        $fclose(fd);
        $finish;
    end
endmodule
