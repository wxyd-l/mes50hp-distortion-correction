// tb_m4_wrback.v -- P2：M4 写回数据正确性
//
// 链路：核心域(50 MHz) M4 输出 -> ud_axi_wr_master -> 写通道(42 MHz) -> 按字地址的 DDR 模型
//       帧结束后【从模型内存按地址读回】整个 1280x720，dump 成 row/col/hex 与黄金模型对拍。
// 判据：写回内容逐像素一致（0 / 921600），页号正确，drop=0，perr=0，且没有任何字被漏写。
//
// 关键点：dump 的是【内存】，不是 de_o/data_o。这一条就是把"输出悬空"变成"真的落进 DDR"。
`timescale 1ns/1ps

module tb_m4_wrback;
    localparam integer TW = 160, SW = 256, H = 720, FW = 1280;
    localparam integer RPB = 120;
    localparam integer BEATS = 10;      // 160 px / 16 px 每拍
    localparam integer PAGE  = 0;       // 纠正帧写在第几页（P2 固定 0，P3 由调度器给）

    parameter integer NT  = 8;
    parameter integer K1Q = 0;
    parameter integer MG  = 8;
    parameter integer A00 = 357914,  A01 = 0,       A02 = -228885965;
    parameter integer A10 = 0,       A11 = 357914,  A12 = -128670062;
    parameter integer H20 = 0, H21 = 0, W0 = 16777216;
    parameter integer LATF = 29;
    parameter integer UX = 65536, UV = 0, U0 = 0;
    parameter integer IV = 65536;
    parameter integer VX = 0, VV = 65536, V0 = 0;
    parameter real    CLKP = 10.0;      // 核心域半周期 ns（10 = 50 MHz）
    parameter real    DDRP = 11.9045;   // DDR 域半周期 ns（42 MHz）
    parameter integer DLY  = 12;        // DDR 读回延迟
    parameter integer WDOG = 0;

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
    wire [11:0] core_row, core_x0;      // 核心给出的、与 de_o 同拍的行号/列条号
    wire fd_req; wire [11:0] fd_row; wire [11:0] fd_x0;
    wire fd_ack; wire [31:0] fd_data; wire fd_data_vld;
    wire fd_abort, fd_pop;
    wire ar_valid; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg  ar_ready = 1; reg [255:0] r_data = 0; reg r_valid = 0; reg r_last = 0;

    ud_row_rd_cdc #(.TW(SW), .FW(FW), .AW(8)) u_rd (
        .clk_c(clk), .rst_c_n(rst_n),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0),
        .fd_abort(fd_abort), .fd_pop(fd_pop),
        .fd_ack(fd_ack), .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .clk_d(clk_ddr), .rst_d_n(rst_n), .page(2'd0),
        .ar_valid(ar_valid), .ar_addr(ar_addr), .ar_len(ar_len), .ar_ready(ar_ready),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last)
    );

    // ---------------- 源帧 DDR 读模型（与 tb_m4_dual 同一图案）----------------
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

    // ---------------- M4 读核 ----------------
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
        .cfg_ux(32'sd65536), .cfg_uv(32'sd0), .cfg_u0(32'sd0),
        .cfg_a00(A00), .cfg_a01(A01), .cfg_a02(A02),
        .cfg_a10(A10), .cfg_a11(A11), .cfg_a12(A12),
        .cfg_h20(H20), .cfg_h21(H21), .cfg_w0(W0),
        .de_o(de_o), .data_o(data_o), .row_done(tile_done),
        .out_row(core_row), .out_x0(core_x0)
    );

    // ---------------- 写主 + 写通道从设备模型 ----------------
    wire w_awvalid, w_wvalid; wire [27:0] w_awaddr; wire [3:0] w_awlen, w_awid;
    wire [255:0] w_wdata; wire [31:0] w_wstrb;
    wire w_wusero_last;
    wire w_wready;
    wire [15:0] hdr_cnt, drop_cnt, perr_cnt;
    reg  w_awready = 1;

    ud_axi_wr_master #(.AW(28), .DW(256), .FW(FW), .PPR(TW), .BEATS(BEATS), .ID(4'd1)) u_wr (
        .clk_c(clk), .rst_c_n(rst_n),
        .de(de_o), .pix(data_o), .out_x0(core_x0), .out_row(core_row),
        .frame_base(28'd0),
        .clk_d(clk_ddr), .rst_d_n(rst_n),
        .awvalid(w_awvalid), .awaddr(w_awaddr), .awlen(w_awlen), .awid(w_awid), .awready(w_awready),
        .wvalid(w_wvalid), .wdata(w_wdata), .wstrb(w_wstrb), .wready(w_wready),
        .wusero_last(w_wusero_last),
        .hdr_cnt(hdr_cnt), .drop_cnt(drop_cnt), .perr_cnt(perr_cnt)
    );

    // 纠正帧内存模型：按【页内字地址】存 32 位（一个 32 位字 = 两个像素）
    localparam integer MEMW = 524288;     // 2^19 字 = 2 MB，覆盖 720*640 = 460800
    reg [31:0] mem [0:MEMW-1];
    reg        wseen [0:MEMW-1];

    reg        wr_rcv = 0;
    reg [4:0]  wr_left = 0;
    reg [3:0]  wr_beat = 0;
    reg [27:0] wr_base;
    reg [2:0]  wbp = 0;
    integer    n_wburst = 0, n_wbeat = 0, werr = 0, n_page_bad = 0;

    wire wr_kick = w_awvalid && w_awready;
    assign w_wready = (wr_rcv || wr_kick) && (wbp != 3'd5);   // 偶尔反压
    assign w_wusero_last = wr_rcv && (wr_left == 5'd1);
    always @(posedge clk_ddr) wbp <= wbp + 1'b1;

    integer wi, nn;
    // 一个 256-bit 拍 = 32 B = 8 个 32 位字 = 16 个像素；落到 8 个连续字上
    task store_beat;
        input [3:0] k;
        input [27:0] base;
        begin
            for (nn = 0; nn < 8; nn = nn + 1) begin
                wi = base[21:0] + (k*8) + nn;
                if (wi >= MEMW) begin werr = werr + 1; end
                else begin mem[wi] <= w_wdata[nn*32 +: 32]; wseen[wi] <= 1'b1; end
            end
        end
    endtask

    always @(posedge clk_ddr) if (rst_n) begin
        if (wr_kick) begin
            if (w_awaddr[27:22] !== PAGE) begin n_page_bad = n_page_bad + 1; end
            if (w_awlen !== BEATS-1) begin $display("ERR awlen=%0d", w_awlen); werr = werr + 1; end
            if (w_awid  !== 4'd1)    begin $display("ERR awid=%0d", w_awid);  werr = werr + 1; end
            wr_base <= w_awaddr;
            wr_rcv  <= 1'b1;
            wr_left <= w_wready ? (BEATS-1) : BEATS;
            wr_beat <= w_wready ? 4'd1 : 4'd0;
            n_wburst = n_wburst + 1;
            if (w_wready) begin
                store_beat(4'd0, w_awaddr);
                if (w_wstrb !== 32'hFFFF_FFFF) begin werr = werr + 1; end
                n_wbeat = n_wbeat + 1;
            end
        end else if (wr_rcv && w_wready) begin
            store_beat(wr_beat, wr_base);
            if (w_wstrb !== 32'hFFFF_FFFF) begin werr = werr + 1; end
            n_wbeat = n_wbeat + 1;
            if (wr_left == 5'd1) begin wr_rcv <= 1'b0; end
            else begin wr_left <= wr_left - 5'd1; wr_beat <= wr_beat + 4'd1; end
        end
    end

    // ---------------- 统计与 dump ----------------
    integer cyc = 0;
    always @(posedge clk) if (rst_n) cyc = cyc + 1;

    integer fd, wr, wc, holes, i2, n_out;
    reg [31:0] word;
    reg [8*128-1:0] dump_name;
    initial begin
        for (i2 = 0; i2 < MEMW; i2 = i2 + 1) begin mem[i2] = 32'd0; wseen[i2] = 1'b0; end
        if (!$value$plusargs("DUMP=%s", dump_name)) dump_name = "rtl_wrback.txt";
        fd = $fopen(dump_name, "w");
        if (fd == 0) begin $display("DUMPOPEN_FAIL %0s", dump_name); $finish; end
        $display("DUMPFILE %0s", dump_name);
        #20 rst_n = 1; @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        repeat (4000) @(posedge clk_ddr);      // 等最后一行突发排空
        // 按地址读回整帧
        holes = 0; n_out = 0;
        for (wr = 0; wr < H; wr = wr + 1) begin
            for (wc = 0; wc < FW; wc = wc + 2) begin
                i2 = wr*(FW/2) + (wc/2);
                if (!wseen[i2]) holes = holes + 1;
                word = mem[i2];
                $fdisplay(fd, "%0d %0d %h", wr, wc,   word[15:0]);
                $fdisplay(fd, "%0d %0d %h", wr, wc+1, word[31:16]);
                n_out = n_out + 2;
            end
        end
        $display("WRBACK tiles=%0d K1Q=%0d pixels=%0d holes=%0d bursts=%0d beats=%0d drop=%0d perr=%0d pagebad=%0d werr=%0d cyc=%0d",
                 NT, K1Q, n_out, holes, n_wburst, n_wbeat, drop_cnt, perr_cnt, n_page_bad, werr, cyc);
        $fclose(fd);
        $finish;
    end
    initial begin if (WDOG > 0) begin #(WDOG);
        $display("WATCHDOG t=%0t bursts=%0d beats=%0d drop=%0d perr=%0d rcv=%b left=%0d",
                 $time, n_wburst, n_wbeat, drop_cnt, perr_cnt, wr_rcv, wr_left); $finish; end end
endmodule
