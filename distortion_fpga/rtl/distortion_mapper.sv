`timescale 1ns/1ps
`default_nettype none

// Brown-Conrady inverse image sampling coordinate generator.
//
// Configuration MUST remain constant while any token is in this pipeline.
// a00..a12: signed Q4.28 inverse affine normalization, applied to integer u,v.
// k1,k2,p1,p2 and normalized intermediates: signed Q8.24.
// fx,fy,cx,cy and src_x,src_y: signed Q16.16.
// Multiplication in Q8.24 discards 24 low bits by arithmetic right shift;
// every narrowing to 32 bits is checked for signed overflow. Negative results
// are therefore rounded toward negative infinity, not toward zero.
//
// There are LATENCY registered stages. A token accepted at enabled edge N
// appears at the output after edge N+LATENCY-1. ce=0 freezes all stages.
// out_valid is a completed TOKEN, including failed calculations. If
// out_overflow=1 its source coordinate is invalid and src_x/src_y are zero.
// A consumer must retire such a token (for example as a black output pixel).
// No camera interface, frame buffer, or device-specific multiplier is implied.
module distortion_mapper (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 ce,
    input  wire                 in_valid,
    input  wire [15:0]          in_u,
    input  wire [15:0]          in_v,
    input  wire signed [31:0]   a00,
    input  wire signed [31:0]   a01,
    input  wire signed [31:0]   a02,
    input  wire signed [31:0]   a10,
    input  wire signed [31:0]   a11,
    input  wire signed [31:0]   a12,
    input  wire signed [31:0]   k1,
    input  wire signed [31:0]   k2,
    input  wire signed [31:0]   p1,
    input  wire signed [31:0]   p2,
    input  wire signed [31:0]   fx,
    input  wire signed [31:0]   fy,
    input  wire signed [31:0]   cx,
    input  wire signed [31:0]   cy,
    output wire                 out_valid,
    output wire                 out_overflow,
    output wire [15:0]          out_u,
    output wire [15:0]          out_v,
    output wire signed [31:0]   src_x,
    output wire signed [31:0]   src_y
);
    localparam integer LATENCY = 12;
    localparam signed [63:0] ONE_Q24 = 64'sd16777216;

    function automatic signed [63:0] ext32(input logic signed [31:0] value);
        ext32 = {{32{value[31]}}, value};
    endfunction
    function automatic signed [63:0] ext49(input logic signed [48:0] value);
        ext49 = {{15{value[48]}}, value};
    endfunction
    function automatic signed [31:0] q24(input logic signed [63:0] product);
        q24 = product[55:24];
    endfunction
    function automatic overflow32(input logic signed [63:0] value);
        overflow32 = (value[63:31] != {33{value[31]}});
    endfunction
    function automatic overflow_q24(input logic signed [63:0] product);
        overflow_q24 = (product[63:55] != {9{product[55]}});
    endfunction

    logic [LATENCY-1:0] valid_pipe;
    logic [LATENCY-1:0] overflow_pipe;
    logic [15:0] u_pipe [0:LATENCY-1];
    logic [15:0] v_pipe [0:LATENCY-1];

    // 0: four exact signed 32x17 inverse-affine products.
    logic signed [48:0] s0_xu, s0_xv, s0_yu, s0_yv;
    // 1: sum in 64 bits; convert Q4.28 to Q8.24.
    logic signed [31:0] s1_x, s1_y;
    // 2: full-precision square/cross products.
    logic signed [31:0] s2_x, s2_y;
    logic signed [63:0] s2_xx, s2_yy, s2_xy;
    // 3: trim the products and add r2.
    logic signed [31:0] s3_x, s3_y, s3_xx, s3_yy, s3_xy, s3_r2;
    // 4: r4, k1*r2, p1*xy, p2*xy; tangent coordinate sums.
    logic signed [31:0] s4_x, s4_y, s4_tx, s4_ty;
    logic signed [63:0] s4_r4, s4_k1r2, s4_p1xy, s4_p2xy;
    // 5: trim products before the following multiplications.
    logic signed [31:0] s5_x, s5_y, s5_tx, s5_ty;
    logic signed [31:0] s5_r4, s5_k1r2, s5_p1xy, s5_p2xy;
    // 6: remaining radial/tangential products.
    logic signed [31:0] s6_x, s6_y, s6_k1r2, s6_p1xy, s6_p2xy;
    logic signed [63:0] s6_k2r4, s6_p2tx, s6_p1ty;
    // 7: radial scale and total tangential displacements.
    logic signed [31:0] s7_x, s7_y, s7_scale, s7_tanx, s7_tany;
    // 8: radial x/y products.
    logic signed [63:0] s8_xrad, s8_yrad;
    logic signed [31:0] s8_tanx, s8_tany;
    // 9: distorted normalized coordinates.
    logic signed [31:0] s9_xd, s9_yd;
    // 10: full-precision camera projection products.
    logic signed [63:0] s10_xfx, s10_yfy;
    // 11: projection offsets, Q16.16 result.
    logic signed [31:0] s11_src_x, s11_src_y;

    wire signed [63:0] affine_x_q28 = ext49(s0_xu) + ext49(s0_xv) + ext32(a02);
    wire signed [63:0] affine_y_q28 = ext49(s0_yu) + ext49(s0_yv) + ext32(a12);
    wire signed [63:0] affine_x_q24 = affine_x_q28 >>> 4;
    wire signed [63:0] affine_y_q24 = affine_y_q28 >>> 4;
    wire signed [63:0] r2_wide = ext32(q24(s2_xx)) + ext32(q24(s2_yy));
    wire signed [63:0] twice_xx = ext32(s3_xx) <<< 1;
    wire signed [63:0] twice_yy = ext32(s3_yy) <<< 1;
    wire signed [63:0] tx_wide = ext32(s3_r2) + twice_xx;
    wire signed [63:0] ty_wide = ext32(s3_r2) + twice_yy;
    wire signed [63:0] scale_partial = ONE_Q24 + ext32(s6_k1r2);
    wire signed [63:0] scale_wide = scale_partial + ext32(q24(s6_k2r4));
    wire signed [63:0] twice_p1xy = ext32(s6_p1xy) <<< 1;
    wire signed [63:0] twice_p2xy = ext32(s6_p2xy) <<< 1;
    wire signed [63:0] tanx_wide = twice_p1xy + ext32(q24(s6_p2tx));
    wire signed [63:0] tany_wide = ext32(q24(s6_p1ty)) + twice_p2xy;
    wire signed [63:0] xd_wide = ext32(q24(s8_xrad)) + ext32(s8_tanx);
    wire signed [63:0] yd_wide = ext32(q24(s8_yrad)) + ext32(s8_tany);
    // Keep the shifted projection in 64 bits for the addition, but flag both
    // the Q16.16 product and the offset sum if either is outside signed32.
    wire signed [63:0] sx_wide = (s10_xfx >>> 24) + ext32(cx);
    wire signed [63:0] sy_wide = (s10_yfy >>> 24) + ext32(cy);

    integer i;
    // Only token/error state needs reset. Uninitialized data is never valid.
    // Reset is synchronous and is honored even when ce is low.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe <= '0;
            overflow_pipe <= '0;
        end else if (ce) begin
            valid_pipe <= {valid_pipe[LATENCY-2:0], in_valid};
            overflow_pipe[0] <= 1'b0;
            overflow_pipe[1] <= overflow32(affine_x_q24) || overflow32(affine_y_q24);
            overflow_pipe[2] <= overflow_pipe[1];
            overflow_pipe[3] <= overflow_pipe[2] || overflow_q24(s2_xx) ||
                                overflow_q24(s2_yy) || overflow_q24(s2_xy) || overflow32(r2_wide);
            overflow_pipe[4] <= overflow_pipe[3] || overflow32(twice_xx) ||
                                overflow32(twice_yy) || overflow32(tx_wide) || overflow32(ty_wide);
            overflow_pipe[5] <= overflow_pipe[4] || overflow_q24(s4_r4) ||
                                overflow_q24(s4_k1r2) || overflow_q24(s4_p1xy) || overflow_q24(s4_p2xy);
            overflow_pipe[6] <= overflow_pipe[5];
            overflow_pipe[7] <= overflow_pipe[6] || overflow_q24(s6_k2r4) ||
                                overflow_q24(s6_p2tx) || overflow_q24(s6_p1ty) ||
                                overflow32(scale_partial) || overflow32(scale_wide) || overflow32(twice_p1xy) ||
                                overflow32(twice_p2xy) || overflow32(tanx_wide) || overflow32(tany_wide);
            overflow_pipe[8] <= overflow_pipe[7];
            overflow_pipe[9] <= overflow_pipe[8] || overflow_q24(s8_xrad) ||
                                overflow_q24(s8_yrad) || overflow32(xd_wide) || overflow32(yd_wide);
            overflow_pipe[10] <= overflow_pipe[9];
            overflow_pipe[11] <= overflow_pipe[10] || overflow_q24(s10_xfx) ||
                                 overflow_q24(s10_yfy) || overflow32(sx_wide) || overflow32(sy_wide);
        end
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            u_pipe[0] <= in_u;
            v_pipe[0] <= in_v;
            for (i = 1; i < LATENCY; i = i + 1) begin
                u_pipe[i] <= u_pipe[i-1];
                v_pipe[i] <= v_pipe[i-1];
            end

            s0_xu <= a00 * $signed({1'b0, in_u});
            s0_xv <= a01 * $signed({1'b0, in_v});
            s0_yu <= a10 * $signed({1'b0, in_u});
            s0_yv <= a11 * $signed({1'b0, in_v});

            s1_x <= affine_x_q24[31:0];
            s1_y <= affine_y_q24[31:0];

            s2_x <= s1_x;
            s2_y <= s1_y;
            s2_xx <= s1_x * s1_x;
            s2_yy <= s1_y * s1_y;
            s2_xy <= s1_x * s1_y;

            s3_x <= s2_x;
            s3_y <= s2_y;
            s3_xx <= q24(s2_xx);
            s3_yy <= q24(s2_yy);
            s3_xy <= q24(s2_xy);
            s3_r2 <= r2_wide[31:0];

            s4_x <= s3_x;
            s4_y <= s3_y;
            s4_tx <= tx_wide[31:0];
            s4_ty <= ty_wide[31:0];
            s4_r4 <= s3_r2 * s3_r2;
            s4_k1r2 <= k1 * s3_r2;
            s4_p1xy <= p1 * s3_xy;
            s4_p2xy <= p2 * s3_xy;

            s5_x <= s4_x;
            s5_y <= s4_y;
            s5_tx <= s4_tx;
            s5_ty <= s4_ty;
            s5_r4 <= q24(s4_r4);
            s5_k1r2 <= q24(s4_k1r2);
            s5_p1xy <= q24(s4_p1xy);
            s5_p2xy <= q24(s4_p2xy);

            s6_x <= s5_x;
            s6_y <= s5_y;
            s6_k1r2 <= s5_k1r2;
            s6_p1xy <= s5_p1xy;
            s6_p2xy <= s5_p2xy;
            s6_k2r4 <= k2 * s5_r4;
            s6_p2tx <= p2 * s5_tx;
            s6_p1ty <= p1 * s5_ty;

            s7_x <= s6_x;
            s7_y <= s6_y;
            s7_scale <= scale_wide[31:0];
            s7_tanx <= tanx_wide[31:0];
            s7_tany <= tany_wide[31:0];

            s8_xrad <= s7_x * s7_scale;
            s8_yrad <= s7_y * s7_scale;
            s8_tanx <= s7_tanx;
            s8_tany <= s7_tany;

            s9_xd <= xd_wide[31:0];
            s9_yd <= yd_wide[31:0];

            s10_xfx <= s9_xd * fx;
            s10_yfy <= s9_yd * fy;

            s11_src_x <= sx_wide[31:0];
            s11_src_y <= sy_wide[31:0];
        end
    end

    assign out_valid = valid_pipe[LATENCY-1];
    assign out_overflow = out_valid && overflow_pipe[LATENCY-1];
    assign out_u = out_valid ? u_pipe[LATENCY-1] : 16'd0;
    assign out_v = out_valid ? v_pipe[LATENCY-1] : 16'd0;
    assign src_x = (out_valid && !out_overflow) ? s11_src_x : 32'sd0;
    assign src_y = (out_valid && !out_overflow) ? s11_src_y : 32'sd0;
endmodule

`default_nettype wire
