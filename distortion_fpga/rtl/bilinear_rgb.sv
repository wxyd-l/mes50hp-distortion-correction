`timescale 1ns/1ps
`default_nettype none

// Three-stage, one-RGB888-token-per-enabled-clock bilinear interpolator.
// p00=(x,y), p10=(x+1,y), p01=(x,y+1), p11=(x+1,y+1).
// wx/wy are the upper 8 fractional bits of the Q16.16 source coordinate.
// The caller supplies border samples; this module has no image dimensions.
// The full four 2-D weights are retained and rounding is applied only once:
// (p00*(256-wx)*(256-wy) + p10*wx*(256-wy) +
//  p01*(256-wx)*wy + p11*wx*wy + 32768) >> 16, for each channel.
// ce=0 freezes valid and all data. Reset is synchronous, active low.
module bilinear_rgb (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         ce,
    input  wire         in_valid,
    input  wire [23:0]  p00,
    input  wire [23:0]  p10,
    input  wire [23:0]  p01,
    input  wire [23:0]  p11,
    input  wire [7:0]   wx,
    input  wire [7:0]   wy,
    output wire         out_valid,
    output wire [23:0]  rgb
);
    localparam integer LATENCY = 3;
    logic [LATENCY-1:0] valid_pipe;
    logic [23:0] s0_p00, s0_p10, s0_p01, s0_p11;
    logic [16:0] s0_w00, s0_w10, s0_w01, s0_w11;
    logic [24:0] s1_p00 [0:2];
    logic [24:0] s1_p10 [0:2];
    logic [24:0] s1_p01 [0:2];
    logic [24:0] s1_p11 [0:2];
    wire [26:0] rounded [0:2];
    logic [23:0] s2_rgb;

    wire [8:0] inv_wx = 9'd256 - {1'b0, wx};
    wire [8:0] inv_wy = 9'd256 - {1'b0, wy};
    genvar channel;
    generate
        for (channel = 0; channel < 3; channel = channel + 1) begin : channel_sum
            assign rounded[channel] = {2'b00, s1_p00[channel]} + {2'b00, s1_p10[channel]} +
                                      {2'b00, s1_p01[channel]} + {2'b00, s1_p11[channel]} + 27'd32768;
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n)
            valid_pipe <= '0;
        else if (ce)
            valid_pipe <= {valid_pipe[LATENCY-2:0], in_valid};
    end

    integer c;
    always_ff @(posedge clk) begin
        if (ce) begin
            s0_p00 <= p00;
            s0_p10 <= p10;
            s0_p01 <= p01;
            s0_p11 <= p11;
            // These products are at most 65536 and fit in 17 bits.
            s0_w00 <= inv_wx * inv_wy;
            s0_w10 <= {1'b0, wx} * inv_wy;
            s0_w01 <= inv_wx * {1'b0, wy};
            s0_w11 <= {1'b0, wx} * {1'b0, wy};
            for (c = 0; c < 3; c = c + 1) begin
                s1_p00[c] <= s0_p00[c*8 +: 8] * s0_w00;
                s1_p10[c] <= s0_p10[c*8 +: 8] * s0_w10;
                s1_p01[c] <= s0_p01[c*8 +: 8] * s0_w01;
                s1_p11[c] <= s0_p11[c*8 +: 8] * s0_w11;
                s2_rgb[c*8 +: 8] <= rounded[c][23:16];
            end
        end
    end

    assign out_valid = valid_pipe[LATENCY-1];
    assign rgb = out_valid ? s2_rgb : 24'd0;
endmodule

`default_nettype wire
