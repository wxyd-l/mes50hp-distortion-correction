`timescale 1ns/1ps
// Backpressured pixel renderer. Logical read addresses count RGB565 pixels,
// not bytes or physical DDR bursts. Adapter holds rsp_valid until rsp_ready.
module undistort_engine #(
    parameter SRC_WIDTH=1280,SRC_HEIGHT=720,
    parameter OUT_WIDTH=1280,OUT_HEIGHT=720,
    parameter GRID_LOG2=5,COORD_FRAC=8,WEIGHT_FRAC=16,
    parameter ADDR_BITS=24,INIT_FILE="",USE_FAST_MAP=0
)(
    input wire clk,rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire [15:0] dst_x,dst_y,
    input wire in_sof,in_eol,
    output wire out_valid,
    input wire out_ready,
    output reg [15:0] out_pixel,
    output wire [15:0] out_x,out_y,
    output wire out_sof,out_eol,
    output reg out_sample_valid,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_BITS-1:0] mem_req_addr,
    input wire mem_rsp_valid,
    output wire mem_rsp_ready,
    input wire [15:0] mem_rsp_data,
    input wire cfg_begin,cfg_we,cfg_commit,
    input wire [15:0] cfg_addr,
    input wire [63:0] cfg_data,
    output wire cfg_ready,cfg_error,active_ready,pending,active_bank,
    input wire frame_start,
    output wire frame_ready,
    output reg protocol_error
);
    localparam IDLE=0,MAP_REQ=1,MAP_WAIT=2,READ_REQ=3,READ_WAIT=4,
               INTERP=5,INTERP_WAIT=6,HOLD=7;
    localparam signed [31:0] MAX_X_Q=(SRC_WIDTH-1)*(1<<COORD_FRAC);
    localparam signed [31:0] MAX_Y_Q=(SRC_HEIGHT-1)*(1<<COORD_FRAC);
    // synthesis translate_off
    initial begin
        if(SRC_WIDTH<2 || SRC_HEIGHT<2 || SRC_WIDTH>65535 || SRC_HEIGHT>65535)
            $fatal(1,"source dimensions must be in [2,65535]");
        if(ADDR_BITS<1 || ADDR_BITS>30 || SRC_WIDTH*64'd1*SRC_HEIGHT>(64'd1<<ADDR_BITS)
                || OUT_WIDTH*64'd1*OUT_HEIGHT>(64'd1<<ADDR_BITS))
            $fatal(1,"pixel addresses do not fit ADDR_BITS [1,30]");
        if((SRC_WIDTH-1)*64'd1*(64'd1<<COORD_FRAC)>64'h7fffffff
                || (SRC_HEIGHT-1)*64'd1*(64'd1<<COORD_FRAC)>64'h7fffffff)
            $fatal(1,"source coordinates exceed signed int32 range");
    end
    // synthesis translate_on
    reg [3:0] state;
    reg [15:0] dx,dy;
    reg sof,eol;
    reg [ADDR_BITS-1:0] addr00,addr10,addr01,addr11;
    reg [1:0] corner;
    reg [15:0] p00,p10,p01,p11;
    reg [COORD_FRAC-1:0] fx,fy;
    wire mapper_ready,mapper_valid,mapper_frame_ready;
    wire signed [31:0] sx_q,sy_q;
    wire pixel_valid;
    wire [15:0] pixel_value;
    integer ix0,iy0,ix1,iy1;
    assign frame_ready=state==IDLE && mapper_frame_ready;
    assign in_ready=state==IDLE && active_ready && !frame_start;
    assign out_valid=state==HOLD;
    assign out_x=dx;assign out_y=dy;assign out_sof=sof;assign out_eol=eol;
    assign mem_req_valid=state==READ_REQ;
    assign mem_rsp_ready=state==READ_WAIT;
    assign mem_req_addr=corner==0 ? addr00 : corner==1 ? addr10 : corner==2 ? addr01 : addr11;
    generate if(USE_FAST_MAP)begin:parallel_map
    grid_mapper_fast #(.OUT_WIDTH(OUT_WIDTH),.OUT_HEIGHT(OUT_HEIGHT),
        .GRID_LOG2(GRID_LOG2),.COORD_FRAC(COORD_FRAC),.WEIGHT_FRAC(WEIGHT_FRAC),.INIT_FILE(INIT_FILE)) mapper (
        .clk(clk),.rst_n(rst_n),.in_valid(state==MAP_REQ),.in_ready(mapper_ready),.dst_x(dx),.dst_y(dy),
        .out_valid(mapper_valid),.out_ready(state==MAP_WAIT),.src_x_q(sx_q),.src_y_q(sy_q),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.active_ready(active_ready),.pending(pending),
        .frame_start(frame_start && frame_ready),.frame_ready(mapper_frame_ready),.active_bank(active_bank));
    end else begin:serial_map
    grid_mapper #(.OUT_WIDTH(OUT_WIDTH),.OUT_HEIGHT(OUT_HEIGHT),
        .GRID_LOG2(GRID_LOG2),.COORD_FRAC(COORD_FRAC),.WEIGHT_FRAC(WEIGHT_FRAC),.INIT_FILE(INIT_FILE)) mapper (
        .clk(clk),.rst_n(rst_n),.in_valid(state==MAP_REQ),.in_ready(mapper_ready),.dst_x(dx),.dst_y(dy),
        .out_valid(mapper_valid),.out_ready(state==MAP_WAIT),.src_x_q(sx_q),.src_y_q(sy_q),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.active_ready(active_ready),.pending(pending),
        .frame_start(frame_start && frame_ready),.frame_ready(mapper_frame_ready),.active_bank(active_bank));
    end endgenerate
    bilinear_rgb565 #(.FRAC_BITS(COORD_FRAC)) interpolate (
        .clk(clk),.rst_n(rst_n),.ce(1'b1),.in_valid(state==INTERP),
        .p00(p00),.p10(p10),.p01(p01),.p11(p11),.fx(fx),.fy(fy),
        .out_valid(pixel_valid),.out_pixel(pixel_value));
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;dx<=0;dy<=0;sof<=0;eol<=0;corner<=0;fx<=0;fy<=0;
            addr00<=0;addr10<=0;addr01<=0;addr11<=0;
            p00<=0;p10<=0;p01<=0;p11<=0;out_pixel<=0;out_sample_valid<=0;protocol_error<=0;
        end else begin
            if(frame_start && !frame_ready) protocol_error<=1;
            case(state)
                IDLE: if(in_valid && in_ready) begin
                    dx<=dst_x;dy<=dst_y;sof<=in_sof;eol<=in_eol;
                    out_pixel<=0;out_sample_valid<=0;
                    if(dst_x>=OUT_WIDTH || dst_y>=OUT_HEIGHT) state<=HOLD;
                    else state<=MAP_REQ;
                end
                MAP_REQ: if(mapper_ready) state<=MAP_WAIT;
                MAP_WAIT: if(mapper_valid) begin
                    if(sx_q<0 || sy_q<0 || sx_q>MAX_X_Q || sy_q>MAX_Y_Q) begin
                        out_pixel<=0;out_sample_valid<=0;state<=HOLD;
                    end else begin
                        ix0=sx_q>>>COORD_FRAC;iy0=sy_q>>>COORD_FRAC;
                        ix1=ix0==SRC_WIDTH-1 ? ix0 : ix0+1;
                        iy1=iy0==SRC_HEIGHT-1 ? iy0 : iy0+1;
                        addr00<=iy0*SRC_WIDTH+ix0;addr10<=iy0*SRC_WIDTH+ix1;
                        addr01<=iy1*SRC_WIDTH+ix0;addr11<=iy1*SRC_WIDTH+ix1;
                        fx<=sx_q[COORD_FRAC-1:0];fy<=sy_q[COORD_FRAC-1:0];
                        corner<=0;out_sample_valid<=1;state<=READ_REQ;
                    end
                end
                READ_REQ: if(mem_req_ready) state<=READ_WAIT;
                READ_WAIT: if(mem_rsp_valid) begin
                    case(corner)
                        0:p00<=mem_rsp_data;
                        1:p10<=mem_rsp_data;
                        2:p01<=mem_rsp_data;
                        3:p11<=mem_rsp_data;
                    endcase
                    if(corner==3) state<=INTERP;
                    else begin corner<=corner+1'b1;state<=READ_REQ;end
                end
                INTERP: state<=INTERP_WAIT;
                INTERP_WAIT: if(pixel_valid) begin out_pixel<=pixel_value;state<=HOLD;end
                HOLD: if(out_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
