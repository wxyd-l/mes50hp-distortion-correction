// tb_ud_bil_m4_dump.v -- M3b 核心逐像素 dump（旋转 + 透视由 -g 传入整数系数）
// Line format: "<v> <u_abs> <value_hex>"
`timescale 1ns/1ps

module tb_ud_bil_m4_dump;
    localparam integer TW = 160, SW = 256, H = 720, FW = 1280;
    localparam integer RPB = 120;

    parameter integer NT  = 8;
    parameter integer K1Q = 0;
    parameter integer MG  = 56;   // 源列窗口 MARGIN（bisect 用 -gMG=xx 切）
    // 团队核 Q4.28（默认 = 恒等仿射）
    parameter integer A00 = 357914,  A01 = 0,       A02 = -228885965;
    parameter integer A10 = 0,       A11 = 357914,  A12 = -128670062;
    // 透视分母 Q8.24: W = W0 + H20*u + H21*v   （恒等/纯旋转: H20=H21=0, W0=2^24）
    parameter integer H20 = 0, H21 = 0, W0 = 16777216;
    parameter integer LATF = 29;
    parameter integer XEXT = 0;      // 实验：0 = 每行只喂 TW 个 token（看那 24 个是否真的不产出）
    parameter integer CLKP = 5;      // 半周期 (ns)：5 = 100 MHz, 10 = 50 MHz, 11.9045 = 42 MHz
    parameter integer DLY  = 12;     // DDR 往返延迟（拍）；默认 12 = 原行为，加大可压出 busy-abort
    // 像素域仿射 Q16.16 与逆映射
    parameter integer UX = 65536, UV = 0, U0 = 0;
    parameter integer IV = 65536;
    parameter integer VX = 0, VV = 65536, V0 = 0;

    reg clk = 0, rst_n = 0;
    always #CLKP clk = ~clk;

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
    wire [11:0] core_row, core_x0;   // 核心给出的、与 de_o 同拍的行号/列条号
    wire fd_req; wire [11:0] fd_row; wire [11:0] fd_x0;
    wire fd_ack; wire [31:0] fd_data; wire fd_data_vld;
    wire ar_valid; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg  ar_ready = 1; reg [255:0] r_data = 0; reg r_valid = 0; reg r_last = 0;

    ud_ddr_row_rd #(.TW(SW), .FW(FW)) rd (
        .clk(clk), .rst_n(rst_n), .page(2'd0), .tile_x0(fd_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

    function [15:0] src;
        input integer r, c;
        begin
            src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31);
        end
    endfunction

    reg [27:0] a_addr; reg [3:0] a_len;
    integer cnt, b, rr, x0i, jj, k2;
    reg [255:0] beat;
    always @(posedge clk) begin
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

    ud_tile_core_m4 #(
        .TW(TW), .SW(SW), .HEIGHT(H), .RPB(RPB), .MARGIN(MG), .K1CFG(K1Q),
        .LATF(LATF), .XEXT(XEXT),
        .P_IV(IV), .P_VX(VX), .P_VV(VV), .P_V0(V0),
        .P_A00(A00), .P_A01(A01), .P_A02(A02),
        .P_A10(A10), .P_A11(A11), .P_A12(A12),
        .P_H20(H20), .P_H21(H21), .P_W0(W0),
        .P_K1(K1Q)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .fd_abort(), .fd_pop(),
        .cfg_ux(UX), .cfg_uv(UV), .cfg_u0(U0),
        .de_o(de_o), .data_o(data_o), .row_done(tile_done),
        .out_row(core_row), .out_x0(core_x0)
    );

    integer fd, tot, cc, curv, curx, i, seen_cnt;
    reg seen [0:8*160*720-1];
    // 归属：行号/列条号取核心输出（与 de_o 同拍）。行间流水后 start_o 不再与像素对齐，
    // 靠 start_o 复位 cc 会在行重叠时整体错位（同样的输出会被记到错误的行）。
    always @(posedge clk) begin
        if (de_o) begin
            seen[core_row*8*160 + core_x0 + cc] = 1'b1;
            if (K1Q != 0) $fdisplay(fd, "%0d %0d %h", core_row, core_x0 + cc, data_o);
            tot = tot + 1;
            cc = (cc == 159) ? 0 : cc + 1;
        end
    end

    reg [8*128-1:0] dump_name;
    initial begin
        tot = 0; cc = 0; curv = 0; curx = 0; seen_cnt = 0;
        for (i = 0; i < 8*160*720; i = i + 1) seen[i] = 1'b0;
        if (!$value$plusargs("DUMP=%s", dump_name)) dump_name = "rtl_dump_m4.txt";
        fd = $fopen(dump_name, "w");
        if (fd == 0) begin $display("DUMPOPEN_FAIL %0s", dump_name); $finish; end
        $display("DUMPFILE %0s", dump_name);
        #20 rst_n = 1; @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        // 行间流水后 row_done 比本行最后一个像素早 LAG+3 拍（不再等排空），
        // 原来 #200 是 200 ns = 20 拍，会把每帧最后 ~32 个像素截掉（假 holes）。
        #2000;   // 200 拍 @10ns
        for (i = 0; i < 8*160*720; i = i + 1) if (!seen[i]) seen_cnt = seen_cnt + 1;
        $display("DUMPM4 tiles=%0d K1Q=%0d H20=%0d H21=%0d W0=%0d pixels=%0d holes=%0d", NT, K1Q, H20, H21, W0, tot, seen_cnt);
        $display("CYCLES %0d (frame @ %0d ns/cycle)", $time / (2*CLKP), 2*CLKP);
        $fclose(fd);
        $finish;
    end
endmodule
