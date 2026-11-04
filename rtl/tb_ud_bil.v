`timescale 1ns/1ps
module tb_ud_bil;
    localparam integer TW = 160, SW = 192, H = 720, FW = 1280;
    parameter  integer NT  = 1;
    parameter  integer K1Q = 0;
    localparam real    K1R = K1Q/16777216.0;   // Q8.24 -> 实数
    parameter  integer TOL = 3;
    localparam integer LAT = 12;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg frame_start = 0;
    wire start_o, frame_done, tile_done;
    wire [11:0] row_v, tile_x0;
    wire [3:0]  tile_idx;

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

    function [15:0] src;
        input integer r, c;
        begin
            src = (((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31);
        end
    endfunction

    // ---------------- 模拟 DDR（12 拍延迟 + 10 拍突发）----------------
    reg [27:0] a_addr; reg [3:0] a_len;
    integer lx = -1;
    always @(posedge clk) if (ar_valid && ar_ready && fd_x0 != lx) begin
        lx = fd_x0;
        $display("  ARW x0=%0d row=%0d col=%0d", fd_x0, fd_row, 0);
    end
    integer cnt, b, rr, x0i, jj, k2;
    reg [255:0] beat;
    always @(posedge clk) begin
        if (!rst_n) begin r_valid <= 0; r_last <= 0; cnt <= 0; b <= 0; end
        else begin
            if (ar_valid && ar_ready) begin
                a_addr <= ar_addr; a_len <= ar_len; cnt <= LAT; b <= 0; r_valid <= 0;
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

    // ---------------- 理想模型（实数运算）----------------
    function real invx; input integer u,v; real x,y,r2;
        begin
            x = (u - 639.5)/750.0; y = (v - 359.5)/750.0; r2 = x*x + y*y;
            invx = x*(1.0 + K1R*r2)*750.0 + 639.5;
        end
    endfunction
    function real invy; input integer u,v; real x,y,r2;
        begin
            x = (u - 639.5)/750.0; y = (v - 359.5)/750.0; r2 = x*x + y*y;
            invy = y*(1.0 + K1R*r2)*750.0 + 359.5;
        end
    endfunction
    function integer iclamp; input real a; input integer hi;
        begin
            if (a < 0.0) iclamp = 0; else if (a > hi) iclamp = hi;
            else iclamp = $rtoi(a);
        end
    endfunction
    function integer chan5; input integer x0,x1; input real w;
        real t; integer r;
        begin t = x0 + (x1-x0)*w; r = $rtoi(t + 0.5);
              if (r < 0) r = 0; if (r > 31) r = 31; chan5 = r; end
    endfunction
    function integer chan6; input integer x0,x1; input real w;
        real t; integer r;
        begin t = x0 + (x1-x0)*w; r = $rtoi(t + 0.5);
              if (r < 0) r = 0; if (r > 63) r = 63; chan6 = r; end
    endfunction
    function [15:0] expect_bil;
        input integer u,v;
        real sx,sy,ax,ay; integer ix,iy,ix1,iy1,p00,p01,p10,p11,rr5,rr6,rbb;
        begin
            sx = invx(u,v); sy = invy(u,v);
            ix = iclamp(sx, FW-1); iy = iclamp(sy, H-1);
            ix1 = (ix >= FW-1) ? FW-1 : ix+1;
            iy1 = (iy >= H-1) ? H-1 : iy+1;
            ax = sx - ix; if (ax < 0.0) ax = 0.0; if (ax > 1.0) ax = 1.0;
            ay = sy - iy; if (ay < 0.0) ay = 0.0; if (ay > 1.0) ay = 1.0;
            p00 = src(iy,ix); p01 = src(iy,ix1); p10 = src(iy1,ix); p11 = src(iy1,ix1);
            rr5 = chan5( chan5((p00>>11)&31,(p10>>11)&31,ay), chan5((p01>>11)&31,(p11>>11)&31,ay), ax );
            rr6 = chan6( chan6((p00>>5)&63, (p10>>5)&63, ay),  chan6((p01>>5)&63, (p11>>5)&63, ay),  ax );
            rbb = chan5( chan5(p00&31, p10&31, ay), chan5(p01&31, p11&31, ay), ax );
            expect_bil = {rr5[4:0], rr6[5:0], rbb[4:0]};
        end
    endfunction

    ud_tile_core_bil #(.TW(TW), .SW(SW), .HEIGHT(H), .RPB(24), .MARGIN(8), .LAG(20), .K1CFG(K1Q)) dut (
        .clk(clk), .rst_n(rst_n), .start(start_o), .row_v(row_v), .tile_x0(tile_x0),
        .fd_req(fd_req), .fd_row(fd_row), .fd_x0(fd_x0), .fd_ack(fd_ack),
        .fd_data(fd_data), .fd_data_vld(fd_data_vld),
        .de_o(de_o), .data_o(data_o), .row_done(tile_done)
    );

    reg seen [0:8*160*720-1];
    integer tot, errs, cc, curv, curx, i, kk, badv, maxd, bad1;
    integer dr, dg, db; reg [15:0] expv;
    always @(posedge clk) begin
        if (start_o) begin curx = tile_x0; curv = row_v; cc = 0; end
        if (de_o) begin
            kk = (curv*8*160) + curx + cc;
            if (seen[kk]) errs = errs + 1;
            else seen[kk] = 1'b1;
            if (K1Q == 0) begin
                if (data_o !== src(curv, curx + cc)) begin
                    errs = errs + 1;
                    if (errs <= 3) $display("  BAD k0 v=%0d x0=%0d c=%0d got=%h exp=%h",
                                            curv, curx, cc, data_o, src(curv,curx+cc));
                end
            end else begin
                expv = expect_bil(curx + cc, curv);
                dr = data_o[15:11] - expv[15:11]; if (dr < 0) dr = -dr;
                dg = data_o[10:5]  - expv[10:5];  if (dg < 0) dg = -dg;
                db = data_o[4:0]   - expv[4:0];   if (db < 0) db = -db;
                if (dr > maxd) maxd = dr;
                if (dg > maxd) maxd = dg;
                if (db > maxd) maxd = db;
                if (dr > TOL || dg > TOL || db > TOL) begin
                    badv = badv + 1;
                    if (curx > 0) begin
                        bad1 = bad1 + 1;
                        if (bad1 <= 4) $display("  TOL1 v=%0d u=%0d x0=%0d got=%h exp=%h d=%0d/%0d/%0d sx=%f sy=%f vy=%f",
                            curv, curx+cc, curx, data_o, expv, dr, dg, db,
                            invx(curx+cc,curv), invy(curx+cc,curv), invy(curx,curv));
                    end
                end
            end
            tot = tot + 1; cc = cc + 1;
        end
    end

    initial begin
        tot = 0; errs = 0; cc = 0; curv = 0; curx = 0; badv = 0; maxd = 0; bad1 = 0;
        for (i = 0; i < 8*160*720; i = i + 1) seen[i] = 1'b0;
        #20 rst_n = 1; @(posedge clk);
        frame_start = 1; @(posedge clk); frame_start = 0;
        @(posedge frame_done);
        #200;
        $display("BIL tiles=%0d K1Q=%0d : pixels=%0d (expect %0d) cover_err=%0d",
                 NT, K1Q, tot, NT*TW*H, errs);
        if (K1Q != 0) $display("  vs ideal model: maxdiff=%0d  over_tol(%0d)=%0d / %0d",
                               maxd, TOL, badv, tot);
        if (tot == NT*TW*H && errs == 0 && badv == 0) $display("*** PASS tile-bil");
        else $display("*** FAIL tile-bil");
        $finish;
    end
endmodule