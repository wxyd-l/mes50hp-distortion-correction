`timescale 1ns/1ps
// Single-clock integration of the functional remapper, line cache and Pango
// read bridge. Source frame must already be complete and immutable in DDR at
// byte base 0. This is not the physical MES50HP/video/DDR-controller top level.
module remap_ddr_read_top #(
    parameter integer WIDTH=64,
    parameter integer HEIGHT=48,
    parameter integer CACHE_LINES=512
)(
    input wire clk, input wire rst_n,
    input wire start, output wire start_ready,
    input wire signed [31:0] a00,a01,a02,a10,a11,a12,
    input wire signed [31:0] k1,k2,p1,p2,fx,fy,cx,cy,
    output wire busy,done,frame_overflow,
    output reg memory_error,
    output wire [31:0] frame_cycles,pixels_emitted,cache_hits,cache_misses,
    output wire out_valid, input wire out_ready,
    output wire [23:0] out_rgb,
    output wire [15:0] out_u,out_v, output wire out_last,
    output wire [27:0] axi_araddr,
    output wire [3:0] axi_arlen,axi_arid,
    output wire axi_arvalid, input wire axi_arready,
    input wire [255:0] axi_rdata,
    input wire [3:0] axi_rid,
    input wire axi_rvalid,axi_rlast
);
    wire cache_idle;
    assign start_ready = !busy && cache_idle;
    wire accepted_start = start && start_ready;
    wire pixel_req_valid,pixel_req_ready,pixel_rsp_valid,pixel_rsp_ready;
    wire [31:0] pixel_req_addr,pixel_rsp_data;
    wire [2:0] pixel_rsp_error;
    wire line_req_valid,line_req_ready,line_rsp_valid,line_rsp_ready;
    wire [31:0] line_req_addr;
    wire [255:0] line_rsp_data;
    wire [2:0] line_rsp_error;
    wire bridge_protocol_error;

    remap_frame_core #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) core (
        .clk(clk),.rst_n(rst_n),.start(accepted_start),
        .a00(a00),.a01(a01),.a02(a02),.a10(a10),.a11(a11),.a12(a12),
        .k1(k1),.k2(k2),.p1(p1),.p2(p2),.fx(fx),.fy(fy),.cx(cx),.cy(cy),
        .busy(busy),.done(done),.frame_overflow(frame_overflow),
        .frame_cycles(frame_cycles),.pixels_emitted(pixels_emitted),
        .mem_req_valid(pixel_req_valid),.mem_req_ready(pixel_req_ready),.mem_req_addr(pixel_req_addr),
        .mem_rsp_valid(pixel_rsp_valid),.mem_rsp_ready(pixel_rsp_ready),.mem_rsp_data(pixel_rsp_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_u(out_u),.out_v(out_v),.out_last(out_last)
    );
    pixel_read_cache #(.LINES(CACHE_LINES)) cache (
        .clk(clk),.rst_n(rst_n),.invalidate(accepted_start),.invalidate_ready(cache_idle),
        .req_valid(pixel_req_valid),.req_ready(pixel_req_ready),.req_addr(pixel_req_addr),
        .rsp_valid(pixel_rsp_valid),.rsp_ready(pixel_rsp_ready),.rsp_data(pixel_rsp_data),.rsp_error(pixel_rsp_error),
        .line_req_valid(line_req_valid),.line_req_ready(line_req_ready),.line_req_addr(line_req_addr),
        .line_rsp_valid(line_rsp_valid),.line_rsp_ready(line_rsp_ready),.line_rsp_data(line_rsp_data),.line_rsp_error(line_rsp_error),
        .hit_count(cache_hits),.miss_count(cache_misses)
    );
    pango_read_bridge bridge (
        .clk(clk),.rst_n(rst_n),
        .req_valid(line_req_valid),.req_ready(line_req_ready),.req_addr(line_req_addr),
        .rsp_valid(line_rsp_valid),.rsp_ready(line_rsp_ready),.rsp_data(line_rsp_data),.rsp_error(line_rsp_error),
        .protocol_error(bridge_protocol_error),
        .axi_araddr(axi_araddr),.axi_arlen(axi_arlen),.axi_arid(axi_arid),
        .axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
        .axi_rdata(axi_rdata),.axi_rid(axi_rid),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast)
    );
    // Keep memory/protocol errors sticky until a coordinated reset. Error
    // responses carry zero data, so even a failure does not drop output tokens.
    always @(posedge clk) begin
        if (!rst_n) memory_error<=0;
        else if (bridge_protocol_error || (pixel_rsp_valid && pixel_rsp_ready && |pixel_rsp_error))
            memory_error<=1;
    end
endmodule
