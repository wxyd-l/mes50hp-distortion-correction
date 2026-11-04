// tb_prof_m4.v -- 吞吐剖面：不写 dump，只数每帧各状态的拍数
`timescale 1ns/1ps

module tb_prof_m4;
    localparam integer TW = 160, SW = 256, H = 720, FW = 1280;
    localparam integer RPB = 120;

    parameter integer NT  = 8;
    parameter integer K1Q = -2248147;
    parameter integer MG  = 8;
    parameter integer A00 = 357914,  A01 = 0,       A02 = -228885965;
    parameter integer A10 = 0,       A11 = 357914,  A12 = -128670062;
    parameter integer H20 = -7189,   H21 = 7651,    W0  = 18624390;
    parameter integer LATF = 29;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

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
    wire ar_valid; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg  ar_ready = 1; reg [255:0] r_data = 0; reg r_valid = 0; reg r_last = 0;

    ud_ddr_row_rd #(.TW(SW), .FW(FW)) rd (
        .clk(clk), .rst_n(rst_n), .tile_x0(fd_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

    function [15:0] src; input integer r, c;
        begin src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31); end
    endfunction

    reg [27:0] a_addr; reg [3:0] a_len;
    integer cnt, b, rr, x0i, jj, k2;
    reg [255:0] beat;
    always @(posedge clk) begin
        if (!rst_n) begin r_valid <= 0; r_last <= 0; cnt <= 0; b <= 0; end
        else begin
            if (ar_valid && ar_ready) begin a_addr <= ar_addr; a_len <= ar_len; cnt <= 12; b <= 0; r_valid <= 0; end
            else if (cnt > 0) begin cnt <= cnt - 1; if (cnt == 1) b <= 0; end
            else if (b <= a_len) begin
                rr = a_addr / (FW/2); x0i = (a_addr % (FW/2)) * 2;
                for (k2 = 0; k2 < 8; k2 = k2 + 1) begin
                    jj = b*8 + k2;
                    beat[k2*32 +: 32] = { src(rr, x0i + 2*jj + 1), src(rr, x0i + 2*jj) };
                end
                r_data <= beat; r_valid <= 1'b1; r_last <= (b == a_len); b <= b + 1;
            end else begin r_valid <= 1'b0; r_last <= 1'b0; end
        end
    end

    ud_tile_core_m4 #(
        .TW(TW), .SW(SW), .HEIGHT(H), .RPB(RPB), .MARGIN(MG), .K1CFG(K1Q), .LATF(LATF),
        .P_A00(A00), .P_A01(A01), .P_A02(A02),
        .P_A10(A10), .P_A11(A11), .P_A12(A12),
        .P_H20(H20), .P_H21(H21), .P_W0(W0), .P_K1(K1Q)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .cfg_ux(32'sd65536), .cfg_uv(32'sd0), .cfg_u0(32'sd0),
        .de_o(de_o), .data_o(data_o), .row_done(tile_done)
    );

    // ---- 剖面计数器 ----
    integer cyc, c_idle, c_pre, c_fill, c_sweep, nfetch, nreload, ndone, maxfill, curfill, npix;
    reg fd_req_d = 0;
    integer cyc_tile [0:7];
    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if (dut.st == 0) c_idle = c_idle + 1;
            else if (dut.st == 1) c_pre = c_pre + 1;
            else if (dut.st == 2) begin c_fill = c_fill + 1; curfill = curfill + 1; end
            else begin c_sweep = c_sweep + 1; if (curfill > maxfill) maxfill = curfill; curfill = 0; end
            if (fd_req && !fd_req_d) nfetch = nfetch + 1;
            if (dut.ld_vtop) nreload = nreload + 1;
            fd_req_d <= fd_req;
            if (de_o) npix = npix + 1;
        end
    end
    integer ti;
    initial begin
        cyc = 0; c_idle = 0; c_pre = 0; c_fill = 0; c_sweep = 0;
        nfetch = 0; nreload = 0; ndone = 0; maxfill = 0; curfill = 0; npix = 0;
        for (ti = 0; ti < 8; ti = ti + 1) cyc_tile[ti] = 0;
        #20 rst_n = 1; @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        #50;
        $display("PROF cycles=%0d sweep=%0d (%.1f%%) fill=%0d (%.1f%%) pre=%0d idle=%0d fx_px=%0d",
                 cyc, c_sweep, 100.0*c_sweep/cyc, c_fill, 100.0*c_fill/cyc, c_pre, c_idle, npix);
        $display("PROF fetches=%0d reloads=%0d rows=%0d  fetch/row=%.2f  maxFillWait=%0d",
                 nfetch, nreload, NT*H, 1.0*nfetch/(NT*H), maxfill);
        $display("PROF 每行理论=%0d 拍, 实际=%.1f 拍", 229, 1.0*cyc/(NT*H));
        $finish;
    end
endmodule
