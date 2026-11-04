// tb_row_cdc.v -- 跨时钟域行取数验证：两个独立时钟 + 中途 abort，逐字比对
`timescale 1ns/1ps
module tb_row_cdc;
    parameter real TCP = 10.0;      // 核域半周期 ns（10 = 50 MHz）
    parameter real TDP = 5.0;       // DDR 域半周期 ns（5 = 100 MHz）
    parameter integer AW = 8;
    parameter integer NROW = 16;
    parameter integer ABORTROW = 3; // 这一行读到第 ABORTAT 个字时 abort
    parameter integer ABORTAT = 50;
    localparam integer FW = 1280, SW = 256, WORDS = SW/2;

    reg clk_c = 0, clk_d = 0, rst_c_n = 0, rst_d_n = 0;
    always #(TCP) clk_c = ~clk_c;
    always #(TDP) clk_d = ~clk_d;

    wire        ar_valid; wire [27:0] ar_addr; wire [3:0] ar_len; reg ar_ready = 1;
    reg  [255:0] r_data = 0; reg r_valid = 0, r_last = 0;
    function [15:0] src; input integer r, c;
        begin src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31); end
    endfunction

    reg [27:0] a_addr; reg [3:0] a_len;
    integer cnt, b, rr, x0i, jj, k2;
    reg [255:0] beat;
    always @(posedge clk_d) begin
        if (!rst_d_n) begin r_valid <= 0; r_last <= 0; cnt <= 0; b <= 0; end
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

    reg         fd_req = 0;
    reg  [11:0] fd_row = 0, fd_x0 = 0;
    wire        fd_ack, fd_data_vld;
    wire [31:0] fd_data;

    ud_row_rd_cdc #(.TW(SW), .FW(FW), .AW(AW)) dut (
        .clk_c(clk_c), .rst_c_n(rst_c_n),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0),
        .fd_ack(fd_ack), .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .fd_abort(1'b0), .fd_pop(fd_data_vld),   // 单元 TB：取到就消费；abort 场景由 tb_m4_dual 覆盖
        .clk_d(clk_d), .rst_d_n(rst_d_n), .page(2'd0),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

    integer row, widx, err, nwords, x0base, exp, do_abort;
    initial begin
        err = 0; nwords = 0;
        #100 rst_c_n = 1; rst_d_n = 1;
        @(posedge clk_c);
        for (row = 0; row < NROW; row = row + 1) begin
            x0base = (row % 8) * 12;
            @(posedge clk_c); fd_row = row; fd_x0 = x0base; fd_req = 1;
            @(posedge clk_c); fd_req = 0;
            @(posedge fd_ack);
            @(posedge clk_c);
            widx = 0;
            do_abort = (row == ABORTROW);
            while (widx < WORDS) begin
                @(posedge clk_c);
                if (fd_data_vld) begin
                    exp = { src(row, x0base + 2*widx + 1), src(row, x0base + 2*widx) };
                    if (fd_data !== exp) begin
                        if (err < 5) $display("MISMATCH row=%0d w=%0d got=%h exp=%h", row, widx, fd_data, exp);
                        err = err + 1;
                    end
                    nwords = nwords + 1;
                    widx = widx + 1;
                end
            end
        end
        #500;
        $display("CDCROW clk_c=%.1fMHz clk_d=%.1fMHz rows=%0d words=%0d expect=%0d err=%0d %s",
                 1000.0/(2*TCP), 1000.0/(2*TDP), NROW, nwords, NROW*WORDS, err,
                 (err == 0 && nwords == NROW*WORDS) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
