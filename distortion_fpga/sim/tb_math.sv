`timescale 1ns/1ps
`default_nettype none

// Portable Icarus/SystemVerilog unit test. No vendor library is required.
// The root integration tests also compare against the Python reference; this
// bench specifically exercises arithmetic extremes, enabled-clock latency,
// bubbles, global stalls, and all 65536 bilinear fractional weight pairs.
module tb_math;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic ce = 1'b1;
    logic map_in_valid = 1'b0;
    logic [15:0] in_u = 0, in_v = 0;
    logic signed [31:0] a00, a01, a02, a10, a11, a12;
    logic signed [31:0] k1, k2, p1, p2, fx, fy, cx, cy;
    wire map_out_valid, map_overflow;
    wire [15:0] out_u, out_v;
    wire signed [31:0] src_x, src_y;
    distortion_mapper mapper (
        .clk(clk), .rst_n(rst_n), .ce(ce), .in_valid(map_in_valid),
        .in_u(in_u), .in_v(in_v), .a00(a00), .a01(a01), .a02(a02),
        .a10(a10), .a11(a11), .a12(a12), .k1(k1), .k2(k2), .p1(p1), .p2(p2),
        .fx(fx), .fy(fy), .cx(cx), .cy(cy), .out_valid(map_out_valid),
        .out_overflow(map_overflow), .out_u(out_u), .out_v(out_v),
        .src_x(src_x), .src_y(src_y)
    );

    logic bil_in_valid = 1'b0;
    logic [23:0] p00 = 0, p10 = 0, p01 = 0, p11 = 0;
    logic [7:0] wx = 0, wy = 0;
    wire bil_out_valid;
    wire [23:0] rgb;
    bilinear_rgb bilinear (
        .clk(clk), .rst_n(rst_n), .ce(ce), .in_valid(bil_in_valid),
        .p00(p00), .p10(p10), .p01(p01), .p11(p11), .wx(wx), .wy(wy),
        .out_valid(bil_out_valid), .rgb(rgb)
    );

    localparam integer MAX_EXPECTED = 100000;
    integer exp_x [0:MAX_EXPECTED-1], exp_y [0:MAX_EXPECTED-1];
    logic [15:0] exp_u [0:MAX_EXPECTED-1], exp_v [0:MAX_EXPECTED-1];
    bit exp_overflow [0:MAX_EXPECTED-1];
    integer map_due [0:MAX_EXPECTED-1], bil_due [0:MAX_EXPECTED-1];
    logic [23:0] exp_rgb [0:MAX_EXPECTED-1];
    integer map_head = 0, map_tail = 0, bil_head = 0, bil_tail = 0;
    integer enabled_edges = 0;
    integer map_checked = 0, bil_checked = 0, overflows_checked = 0, stall_edges = 0;
    logic [31:0] rng_state = 32'h137fabc9;
    bit ref_overflow;
    integer ref_x, ref_y;
    logic [97:0] map_hold;
    logic [24:0] bil_hold;

    function automatic [31:0] random32;
        begin
            rng_state = rng_state ^ (rng_state << 13);
            rng_state = rng_state ^ (rng_state >> 17);
            rng_state = rng_state ^ (rng_state << 5);
            random32 = rng_state;
        end
    endfunction

    task automatic narrow32(input longint signed value, output integer result, inout bit overflow);
        begin
            if (value < -64'sd2147483648 || value > 64'sd2147483647)
                overflow = 1'b1;
            result = value[31:0];
        end
    endtask

    task automatic mul_q24(input integer lhs, input integer rhs,
                           output integer result, inout bit overflow);
        longint signed product;
        begin
            product = longint'(lhs) * longint'(rhs);
            narrow32(product >>> 24, result, overflow);
        end
    endtask

    task automatic reference_map(input integer u, input integer v,
                                 output integer sx, output integer sy, output bit overflow);
        integer x, y, xx, yy, xy, r2, r4, radial1, radial2, scale;
        integer twice_xx, twice_yy, tx, ty, p1xy, p2xy, tangent_x, tangent_y;
        integer doubled_p1xy, doubled_p2xy, term_x, term_y, radial_x, radial_y, xd, yd;
        integer projected_x, projected_y;
        longint signed wide;
        begin
            overflow = 1'b0;
            wide = longint'(a00)*u + longint'(a01)*v + longint'(a02);
            narrow32(wide >>> 4, x, overflow);
            wide = longint'(a10)*u + longint'(a11)*v + longint'(a12);
            narrow32(wide >>> 4, y, overflow);
            mul_q24(x, x, xx, overflow);
            mul_q24(y, y, yy, overflow);
            mul_q24(x, y, xy, overflow);
            narrow32(longint'(xx) + yy, r2, overflow);
            mul_q24(r2, r2, r4, overflow);
            mul_q24(k1, r2, radial1, overflow);
            mul_q24(k2, r4, radial2, overflow);
            narrow32(64'sd16777216 + radial1, scale, overflow);
            narrow32(longint'(scale) + radial2, scale, overflow);
            narrow32(longint'(xx)*2, twice_xx, overflow);
            narrow32(longint'(yy)*2, twice_yy, overflow);
            narrow32(longint'(r2) + twice_xx, tx, overflow);
            narrow32(longint'(r2) + twice_yy, ty, overflow);
            mul_q24(p1, xy, p1xy, overflow);
            mul_q24(p2, xy, p2xy, overflow);
            narrow32(longint'(p1xy)*2, doubled_p1xy, overflow);
            narrow32(longint'(p2xy)*2, doubled_p2xy, overflow);
            mul_q24(p2, tx, term_x, overflow);
            mul_q24(p1, ty, term_y, overflow);
            narrow32(longint'(doubled_p1xy) + term_x, tangent_x, overflow);
            narrow32(longint'(term_y) + doubled_p2xy, tangent_y, overflow);
            mul_q24(x, scale, radial_x, overflow);
            mul_q24(y, scale, radial_y, overflow);
            narrow32(longint'(radial_x) + tangent_x, xd, overflow);
            narrow32(longint'(radial_y) + tangent_y, yd, overflow);
            mul_q24(xd, fx, projected_x, overflow);
            mul_q24(yd, fy, projected_y, overflow);
            narrow32(longint'(projected_x) + cx, sx, overflow);
            narrow32(longint'(projected_y) + cy, sy, overflow);
            if (overflow) begin sx = 0; sy = 0; end
        end
    endtask

    function automatic [23:0] reference_bilinear(input logic [23:0] q00, q10, q01, q11,
                                               input integer xweight, yweight);
        integer c, value;
        integer w00, w10, w01, w11;
        begin
            w00 = (256-xweight)*(256-yweight);
            w10 = xweight*(256-yweight);
            w01 = (256-xweight)*yweight;
            w11 = xweight*yweight;
            for (c = 0; c < 3; c = c + 1) begin
                value = q00[c*8 +: 8]*w00 + q10[c*8 +: 8]*w10 +
                        q01[c*8 +: 8]*w01 + q11[c*8 +: 8]*w11 + 32768;
                reference_bilinear[c*8 +: 8] = (value >> 16);
            end
        end
    endfunction

    // An output is consumed at the next enabled edge after it becomes visible.
    // Thus queue due dates count LATENCY from the input consumption edge.
    always @(posedge clk) begin
        map_hold = {map_out_valid, map_overflow, out_u, out_v, src_x, src_y};
        bil_hold = {bil_out_valid, rgb};
        if (!rst_n) begin
            map_head = 0; map_tail = 0;
            bil_head = 0; bil_tail = 0;
            enabled_edges = 0;
        end else if (ce) begin
            if (map_out_valid) begin
                if (map_head >= map_tail) $fatal(1, "mapper emitted an unexpected token");
                if (enabled_edges != map_due[map_head])
                    $fatal(1, "mapper enabled-clock latency mismatch");
                if (out_u !== exp_u[map_head] || out_v !== exp_v[map_head] ||
                    src_x !== exp_x[map_head] || src_y !== exp_y[map_head] ||
                    map_overflow !== exp_overflow[map_head])
                    $fatal(1, "mapper #%0d uv=%0d,%0d got=%0d,%0d ov=%b expected=%0d,%0d ov=%b",
                        map_checked, out_u, out_v, src_x, src_y, map_overflow,
                        exp_x[map_head], exp_y[map_head], exp_overflow[map_head]);
                map_checked = map_checked + 1;
                if (map_overflow) overflows_checked = overflows_checked + 1;
                map_head = map_head + 1;
            end
            if (bil_out_valid) begin
                if (bil_head >= bil_tail) $fatal(1, "bilinear emitted an unexpected token");
                if (enabled_edges != bil_due[bil_head])
                    $fatal(1, "bilinear enabled-clock latency mismatch");
                if (rgb !== exp_rgb[bil_head])
                    $fatal(1, "bilinear #%0d got=%h expected=%h", bil_checked, rgb, exp_rgb[bil_head]);
                bil_head = bil_head + 1;
                bil_checked = bil_checked + 1;
            end
            if (map_in_valid) begin
                if (map_tail >= MAX_EXPECTED) $fatal(1, "mapper test queue full");
                reference_map(in_u, in_v, ref_x, ref_y, ref_overflow);
                exp_x[map_tail] = ref_x; exp_y[map_tail] = ref_y;
                exp_overflow[map_tail] = ref_overflow;
                exp_u[map_tail] = in_u; exp_v[map_tail] = in_v;
                map_due[map_tail] = enabled_edges + mapper.LATENCY;
                map_tail = map_tail + 1;
            end
            if (bil_in_valid) begin
                if (bil_tail >= MAX_EXPECTED) $fatal(1, "bilinear test queue full");
                exp_rgb[bil_tail] = reference_bilinear(p00,p10,p01,p11,wx,wy);
                bil_due[bil_tail] = enabled_edges + bilinear.LATENCY;
                bil_tail = bil_tail + 1;
            end
            enabled_edges = enabled_edges + 1;
        end else begin
            stall_edges = stall_edges + 1;
        end
        #1;
        if (!rst_n && (map_out_valid !== 1'b0 || bil_out_valid !== 1'b0))
            $fatal(1, "reset must clear valid even when ce=0");
        if (rst_n && !ce) begin
            if ({map_out_valid,map_overflow,out_u,out_v,src_x,src_y} !== map_hold)
                $fatal(1, "mapper changed while ce=0");
            if ({bil_out_valid,rgb} !== bil_hold)
                $fatal(1, "bilinear changed while ce=0");
        end
    end

    task automatic step(input bit enabled, input bit mv, input bit bv);
        begin
            @(negedge clk);
            ce = enabled;
            map_in_valid = mv;
            bil_in_valid = bv;
        end
    endtask

    task automatic drain;
        begin
            repeat (16) step(1'b1,1'b0,1'b0);
            @(posedge clk); #2;
            if (map_head != map_tail || bil_head != bil_tail)
                $fatal(1, "pipeline drain lost tokens");
        end
    endtask

    task automatic identity_config;
        begin
            a00=32'sd1048576; a01=0; a02=-32'sd134217728;
            a10=0; a11=32'sd1048576; a12=-32'sd67108864;
            k1=0; k2=0; p1=0; p2=0;
            fx=32'sd16777216; fy=32'sd16777216;
            cx=32'sd8388608; cy=32'sd4194304;
        end
    endtask

    integer n, c;
    logic [31:0] random_control;
    initial begin
        identity_config();
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        // Identity plus negative normalized coordinates, bubbles and stalls.
        for (n=0; n<2048; n=n+1) begin
            random_control = random32();
            step(random_control[1:0] != 0, random_control[3:2] != 0, 1'b1);
            in_u=n%512; in_v=(n*7)%256;
            p00=random32(); p10=random32(); p01=random32(); p11=random32();
            wx=random32(); wy=random32();
        end
        drain();
        // Affine cross terms and all four nonzero distortion coefficients.
        a01=32'sd131072; a02=-32'sd214748365;
        a10=-32'sd65536; a12=-32'sd107374182;
        k1=-32'sd3355443; k2=32'sd587203; p1=32'sd33554; p2=-32'sd25166;
        fx=32'sd26214400; fy=32'sd27525120; cx=32'sd20971520; cy=32'sd15728640;
        for (n=0; n<4096; n=n+1) begin
            random_control = random32();
            step(random_control[1:0] != 0, random_control[3:2] != 0, 1'b1);
            in_u=random32()%640; in_v=random32()%480;
            p00=random32(); p10=random32(); p01=random32(); p11=random32();
            wx=random32(); wy=random32();
        end
        drain();
        // Affine, square/r4, radial, tangential and projection overflow cases.
        for (c=0; c<7; c=c+1) begin
            identity_config();
            a00=0; a01=0; a02=32'sd268435456;
            a10=0; a11=0; a12=32'sd268435456;
            case (c)
                0: begin a00=32'sh7fffffff; end
                1: begin a00=32'sd268435456; end
                2: begin a02=32'sd1073741824; a12=0; end
                3: begin k1=32'sh7fffffff; end
                4: begin p1=32'sh7fffffff; p2=32'sh80000000; end
                5: begin fx=32'sh7fffffff; cx=32'sh7fffffff; end
                6: begin k1=32'sh7f000000; k2=-32'sd16777216; a12=0; end
            endcase
            for (n=0; n<64; n=n+1) begin
                random_control = random32();
                step(random_control[1:0] != 0, 1'b1, 1'b0);
                in_u=(c==0) ? 16'hffff : 16'd16;
                in_v=n;
            end
            drain();
        end
        // Arbitrary coefficient bit patterns check failure tokens as well.
        for (c=0; c<32; c=c+1) begin
            a00=random32(); a01=random32(); a02=random32();
            a10=random32(); a11=random32(); a12=random32();
            k1=random32(); k2=random32(); p1=random32(); p2=random32();
            fx=random32(); fy=random32(); cx=random32(); cy=random32();
            for (n=0; n<16; n=n+1) begin
                step(1'b1,1'b1,1'b0);
                in_u=random32(); in_v=random32();
            end
            drain();
        end
        // Exhaust every fractional pair: includes endpoints 0 and 255 and
        // checks that no separable intermediate rounding has been introduced.
        for (n=0; n<65536; n=n+1) begin
            step(1'b1,1'b0,1'b1);
            wx=n[7:0]; wy=n[15:8];
            p00=24'h003fff; p10=24'hffb000; p01=24'h8000aa; p11=24'hffffff;
        end
        step(1'b1,1'b0,1'b1);
        p00=0; p10=24'h010101; p01=0; p11=0; wx=128; wy=0;
        for (n=0; n<256; n=n+1) begin
            step(1'b1,1'b0,1'b1);
            p00=24'hffffff; p10=24'hffffff; p01=24'hffffff; p11=24'hffffff;
            wx=n[7:0]; wy=255-n;
        end
        drain();
        if (map_checked < 3500 || bil_checked < 65536 || overflows_checked < 800 || stall_edges < 500)
            $fatal(1, "test stimulus coverage unexpectedly low");

        // Flush occupied pipelines with reset while global CE is held low.
        identity_config();
        repeat (2) step(1'b1,1'b1,1'b1);
        step(1'b0,1'b0,1'b0);
        rst_n=1'b0;
        repeat (2) @(negedge clk);
        rst_n=1'b1;
        drain();
        $display("PASS tb_math: mapper=%0d overflow=%0d bilinear=%0d stall_edges=%0d",
                 map_checked, overflows_checked, bil_checked, stall_edges);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "tb_math timeout");
    end
endmodule

`default_nettype wire
