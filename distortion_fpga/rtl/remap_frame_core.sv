`timescale 1ns/1ps
// Functional frame reference integration. One outstanding pixel read at a time.
// This deliberately exposes memory latency; it is NOT a 1080p DDR implementation.
module remap_frame_core #(
    parameter integer WIDTH = 64,
    parameter integer HEIGHT = 48,
    parameter integer PROJECTIVE = 0,
    parameter integer POSITIVE_DEPTH = 0
)(
    input wire clk, input wire rst_n,
    input wire start,
    input wire signed [31:0] a00, a01, a02, a10, a11, a12,
    input wire signed [31:0] a20, a21, a22,
    input wire signed [31:0] k1, k2, p1, p2,
    input wire signed [31:0] fx, fy, cx, cy,
    output reg busy, output reg done,
    output reg frame_overflow,
    output reg [31:0] frame_cycles, output reg [31:0] pixels_emitted,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [31:0] mem_req_addr,
    input wire mem_rsp_valid, output wire mem_rsp_ready,
    input wire [31:0] mem_rsp_data,
    output wire out_valid, input wire out_ready,
    output reg [23:0] out_rgb,
    output reg [15:0] out_u, out_v,
    output wire out_last
);
    localparam IDLE=3'd0, TAP=3'd1, WAIT_MEM=3'd2,
               BLEND=3'd3, WAIT_BLEND=3'd4, EMIT=3'd5;
    reg [2:0] state;
    reg signed [31:0] cfg [0:16];
    reg scan_valid;
    reg [15:0] scan_u, scan_v;
    wire map_valid, map_overflow;
    wire [15:0] map_u, map_v;
    wire signed [31:0] map_x, map_y;
    wire map_accept = busy && (state == IDLE);
    wire map_ce = !map_valid || map_accept;
    wire map_ready;
    reg signed [31:0] sample_x, sample_y;
    reg [15:0] sample_u, sample_v;
    reg [1:0] tap_index;
    reg [23:0] taps [0:3];
    wire signed [31:0] tap_x = (sample_x >>> 16) + (tap_index[0] ? 32'sd1 : 32'sd0);
    wire signed [31:0] tap_y = (sample_y >>> 16) + (tap_index[1] ? 32'sd1 : 32'sd0);
    wire tap_in_bounds = (tap_x >= 0) && (tap_x < WIDTH) &&
                         (tap_y >= 0) && (tap_y < HEIGHT);
    assign mem_req_valid = busy && (state == TAP) && tap_in_bounds;
    assign mem_req_addr = tap_in_bounds ? ((tap_y * WIDTH + tap_x) << 2) : 32'd0;
    assign mem_rsp_ready = busy && (state == WAIT_MEM);
    assign out_valid = busy && (state == EMIT);
    assign out_last = out_valid && (out_u == WIDTH-1) && (out_v == HEIGHT-1);
    wire blend_valid;
    wire [23:0] blend_rgb;

    generate if (PROJECTIVE) begin: projective_path
    projective_distortion_mapper #(.POSITIVE_DEPTH(POSITIVE_DEPTH)) mapper (
        .clk(clk), .rst_n(rst_n), .ce(map_ce),
        .in_valid(scan_valid), .in_ready(map_ready), .in_u(scan_u), .in_v(scan_v),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .k1(cfg[6]),.k2(cfg[7]),.p1(cfg[8]),.p2(cfg[9]),
        .fx(cfg[10]),.fy(cfg[11]),.cx(cfg[12]),.cy(cfg[13]),
        .a20(cfg[14]),.a21(cfg[15]),.a22(cfg[16]),
        .out_valid(map_valid),.out_overflow(map_overflow),
        .out_u(map_u),.out_v(map_v),.src_x(map_x),.src_y(map_y)
    );
    end else begin: affine_path
    assign map_ready=map_ce;
    distortion_mapper mapper (
        .clk(clk), .rst_n(rst_n), .ce(map_ce),
        .in_valid(scan_valid), .in_u(scan_u), .in_v(scan_v),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .k1(cfg[6]),.k2(cfg[7]),.p1(cfg[8]),.p2(cfg[9]),
        .fx(cfg[10]),.fy(cfg[11]),.cx(cfg[12]),.cy(cfg[13]),
        .out_valid(map_valid),.out_overflow(map_overflow),
        .out_u(map_u),.out_v(map_v),.src_x(map_x),.src_y(map_y)
    );
    end endgenerate
    bilinear_rgb blender (
        .clk(clk),.rst_n(rst_n),.ce(1'b1),.in_valid(busy && state == BLEND),
        .p00(taps[0]),.p10(taps[1]),.p01(taps[2]),.p11(taps[3]),
        .wx(sample_x[15:8]),.wy(sample_y[15:8]),
        .out_valid(blend_valid),.rgb(blend_rgb)
    );
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy<=0; done<=0; frame_overflow<=0; frame_cycles<=0; pixels_emitted<=0;
            state<=IDLE; scan_valid<=0; scan_u<=0; scan_v<=0;
            sample_x<=0; sample_y<=0; sample_u<=0; sample_v<=0;
            tap_index<=0; out_rgb<=0; out_u<=0; out_v<=0;
            for (i=0;i<17;i=i+1) cfg[i]<=0;
            for (i=0;i<4;i=i+1) taps[i]<=0;
        end else begin
            done<=0;
            if (start && !busy) begin
                cfg[0]<=a00; cfg[1]<=a01; cfg[2]<=a02;
                cfg[3]<=a10; cfg[4]<=a11; cfg[5]<=a12;
                cfg[6]<=k1; cfg[7]<=k2; cfg[8]<=p1; cfg[9]<=p2;
                cfg[10]<=fx; cfg[11]<=fy; cfg[12]<=cx; cfg[13]<=cy;
                cfg[14]<=a20;cfg[15]<=a21;cfg[16]<=a22;
                busy<=1; state<=IDLE; scan_valid<=1; scan_u<=0; scan_v<=0;
                frame_overflow<=0; frame_cycles<=0; pixels_emitted<=0;
            end else if (busy) begin
                frame_cycles<=frame_cycles+1'b1;
                if (scan_valid && map_ready) begin
                    if (scan_u == WIDTH-1) begin
                        scan_u<=0;
                        if (scan_v == HEIGHT-1) scan_valid<=0;
                        else scan_v<=scan_v+1'b1;
                    end else scan_u<=scan_u+1'b1;
                end
                case (state)
                    IDLE: if (map_valid) begin
                        sample_x<=map_x; sample_y<=map_y;
                        sample_u<=map_u; sample_v<=map_v; tap_index<=0;
                        if (map_overflow) begin
                            frame_overflow<=1;
                            for (i=0;i<4;i=i+1) taps[i]<=0;
                            state<=BLEND;
                        end else state<=TAP;
                    end
                    TAP: begin
                        if (!tap_in_bounds) begin
                            taps[tap_index]<=0;
                            if (tap_index==3) state<=BLEND;
                            else tap_index<=tap_index+1'b1;
                        end else if (mem_req_ready) state<=WAIT_MEM;
                    end
                    WAIT_MEM: if (mem_rsp_valid) begin
                        taps[tap_index]<=mem_rsp_data[23:0];
                        if (tap_index==3) state<=BLEND;
                        else begin tap_index<=tap_index+1'b1; state<=TAP; end
                    end
                    BLEND: state<=WAIT_BLEND;
                    WAIT_BLEND: if (blend_valid) begin
                        out_rgb<=blend_rgb; out_u<=sample_u; out_v<=sample_v;
                        state<=EMIT;
                    end
                    EMIT: if (out_ready) begin
                        pixels_emitted<=pixels_emitted+1'b1;
                        state<=IDLE;
                        if (out_last) begin busy<=0; done<=1; end
                    end
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
