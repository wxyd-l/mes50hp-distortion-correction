// tb_board_top.v -- 直接测 ud_board_top（要上板的那个顶层），双时钟 + DDR 行为模型
`timescale 1ns/1ps

module tb_board_top;
    localparam integer FW = 1280, H = 720, TW = 160, NT = 8;
    parameter integer K1Q = -2248147;
    parameter integer A00 = 357914,  A01 = 0,       A02 = -228885965;
    parameter integer A10 = 0,       A11 = 357914,  A12 = -128670062;
    parameter integer H20 = 0, H21 = 0, W0 = 16777216;
    parameter real    CLKP = 10.0;      // 核心域半周期 ns
    parameter real    DDRP = 11.9045;   // DDR 域半周期 ns
    parameter integer DLY  = 12;
    parameter integer WDOG = 0;

    reg clk = 0, clk_ddr = 0, rst_n = 0;
    always #CLKP clk     = ~clk;
    always #DDRP clk_ddr = ~clk_ddr;

    reg  frame_start = 0;
    wire frame_done;
    wire ar_valid; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg  ar_ready = 1; reg [255:0] r_data = 0; reg r_valid = 0; reg r_last = 0;
    wire de_o; wire [15:0] data_o; wire [11:0] out_x0, out_row;

    ud_board_top dut (
        .clk(clk), .clk_ddr(clk_ddr), .rst_n(rst_n),
        .frame_start(frame_start), .frame_done(frame_done),
        .cfg_a00(A00), .cfg_a01(A01), .cfg_a02(A02),
        .cfg_a10(A10), .cfg_a11(A11), .cfg_a12(A12),
        .cfg_h20(H20), .cfg_h21(H21), .cfg_w0(W0),
        .page_rd(2'd0),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last),
        .de_o(de_o), .data_o(data_o), .out_x0(out_x0), .out_row(out_row)
    );

    // DDR 行为模型（clk_ddr 域）
    function [15:0] src;
        input integer r, c;
        begin src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31); end
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

    // 像素 dump + 覆盖统计
    integer fd, tot, holes, i, cc, last_x0, last_row, cyc;
    reg seen [0:NT*TW*H-1];
    always @(posedge clk) if (rst_n) cyc = cyc + 1;
    always @(posedge clk) begin
        if (de_o) begin
            if (out_x0 != last_x0 || out_row != last_row) begin last_x0 = out_x0; last_row = out_row; cc = 0; end
            seen[(out_row*NT + out_x0/TW)*TW + cc] = 1'b1;
            if (K1Q != 0) $fdisplay(fd, "%0d %0d %h", out_row, out_x0 + cc, data_o);
            tot = tot + 1; cc = cc + 1;
        end
    end

    reg [8*128-1:0] dump_name;
    initial begin
        tot = 0; cc = 0; holes = 0; cyc = 0; last_x0 = -1; last_row = -1;
        for (i = 0; i < NT*TW*H; i = i + 1) seen[i] = 1'b0;
        if (!$value$plusargs("DUMP=%s", dump_name)) dump_name = "rtl_board.txt";
        fd = $fopen(dump_name, "w");
        if (fd == 0) begin $display("DUMPOPEN_FAIL %0s", dump_name); $finish; end
        $display("DUMPFILE %0s", dump_name);
        if (WDOG > 0) begin
            #(WDOG);
            $display("WATCHDOG t=%0t pixels=%0d", $time, tot);
            $finish;
        end
        #20 rst_n = 1;
        // 顶层有复位同步（异步置位、同步释放），必须等它释放后再发 frame_start
        wait (dut.rst_c_n === 1'b1);
        repeat (4) @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        #2000;   // 行间流水后 row_done 比本行最后一个像素早 LAG+3 拍，200 ns(=20 拍) 会截掉行尾
        for (i = 0; i < NT*TW*H; i = i + 1) if (!seen[i]) holes = holes + 1;
        $display("BOARDTOP tiles=%0d K1Q=%0d pixels=%0d holes=%0d cyc=%0d", NT, K1Q, tot, holes, cyc);
        $fclose(fd);
        $finish;
    end
endmodule
