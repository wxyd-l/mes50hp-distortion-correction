`timescale 1ns/1ps
// Formula-comparison branch: normalized RGB565, logical pixel addresses,
// whole-sample black border and replicated final neighbor, like our LUT branch.
// Frame-start atomically latches 14 signed32 parameters packed little-field-first:
// a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy.
// One pixel outstanding. Joint reset of source backend/cache is mandatory.
// done means last write accepted, NOT DDR visibility or HDMI frame timing.
module brown_frame_writer #(
    parameter SRC_WIDTH=1280,SRC_HEIGHT=720,OUT_WIDTH=1280,OUT_HEIGHT=720,ADDR_BITS=24
)(
    input wire clk,rst_n,start,
    input wire [447:0] parameters,
    output wire start_ready,busy,
    output reg done,
    output reg [31:0] invalid_pixels,overflow_pixels,
    output reg protocol_error,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_BITS-1:0] mem_req_addr,
    input wire mem_rsp_valid,
    output wire mem_rsp_ready,
    input wire [15:0] mem_rsp_data,
    output wire wr_valid,
    input wire wr_ready,
    output wire [ADDR_BITS-1:0] wr_addr,
    output reg [15:0] wr_data
);
    localparam IDLE=0,MAP_SEND=1,MAP_WAIT=2,READ_REQ=3,READ_WAIT=4,INTERP=5,INTERP_WAIT=6,WRITE_HOLD=7;
    localparam signed [31:0] MAX_X=(SRC_WIDTH-1)*65536,MAX_Y=(SRC_HEIGHT-1)*65536;
    reg [3:0] state;
    reg [447:0] cfg;
    reg [15:0] x,y;
    reg [ADDR_BITS-1:0] index;
    reg [ADDR_BITS-1:0] addresses[0:3];
    reg [15:0] pixels[0:3];
    reg [1:0] corner;
    reg [15:0] fx,fy;
    reg sample_valid,sample_overflow;
    wire mapped,mapping_overflow,pixel_valid;
    wire signed [31:0] sx,sy;
    wire [15:0] pixel_value;
    integer ix0,iy0,ix1,iy1,i;
    assign busy=state!=IDLE;
    assign start_ready=rst_n && state==IDLE;
    assign mem_req_valid=rst_n && state==READ_REQ;
    assign mem_req_addr=addresses[corner];
    assign mem_rsp_ready=rst_n && state==READ_WAIT;
    assign wr_valid=rst_n && state==WRITE_HOLD;
    assign wr_addr=index;
    // synthesis translate_off
    initial begin
        if(SRC_WIDTH<2 || SRC_HEIGHT<2 || SRC_WIDTH>32768 || SRC_HEIGHT>32768 ||
           OUT_WIDTH<2 || OUT_HEIGHT<2 || OUT_WIDTH>65535 || OUT_HEIGHT>65535 ||
           ADDR_BITS<1 || ADDR_BITS>30 || SRC_WIDTH*64'd1*SRC_HEIGHT>(64'd1<<ADDR_BITS) ||
           OUT_WIDTH*64'd1*OUT_HEIGHT>(64'd1<<ADDR_BITS)) $fatal(1,"formula dimensions/address/coordinate overflow");
    end
    // synthesis translate_on
    brown_mapper_pipeline mapper(
        .clk(clk),.rst_n(rst_n),.ce(1'b1),.in_valid(rst_n && state==MAP_SEND),.in_u(x),.in_v(y),
        .a00(cfg[0*32+:32]),.a01(cfg[1*32+:32]),.a02(cfg[2*32+:32]),
        .a10(cfg[3*32+:32]),.a11(cfg[4*32+:32]),.a12(cfg[5*32+:32]),
        .k1(cfg[6*32+:32]),.k2(cfg[7*32+:32]),.p1(cfg[8*32+:32]),.p2(cfg[9*32+:32]),
        .fx(cfg[10*32+:32]),.fy(cfg[11*32+:32]),.cx(cfg[12*32+:32]),.cy(cfg[13*32+:32]),
        .out_valid(mapped),.out_overflow(mapping_overflow),.out_u(),.out_v(),.src_x(sx),.src_y(sy));
    bilinear_rgb565 #(.FRAC_BITS(16)) interpolate(
        .clk(clk),.rst_n(rst_n),.ce(1'b1),.in_valid(rst_n && state==INTERP),
        .p00(pixels[0]),.p10(pixels[1]),.p01(pixels[2]),.p11(pixels[3]),.fx(fx),.fy(fy),
        .out_valid(pixel_valid),.out_pixel(pixel_value));
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;cfg<=0;x<=0;y<=0;index<=0;corner<=0;fx<=0;fy<=0;wr_data<=0;
            done<=0;invalid_pixels<=0;overflow_pixels<=0;protocol_error<=0;sample_valid<=0;sample_overflow<=0;
            for(i=0;i<4;i=i+1)begin addresses[i]<=0;pixels[i]<=0;end
        end else begin
            done<=0;
            if(start && !start_ready)protocol_error<=1;
            case(state)
                IDLE: if(start && start_ready)begin
                    cfg<=parameters;x<=0;y<=0;index<=0;invalid_pixels<=0;overflow_pixels<=0;state<=MAP_SEND;
                end
                MAP_SEND: state<=MAP_WAIT;
                MAP_WAIT: if(mapped)begin
                    sample_overflow<=mapping_overflow;
                    if(mapping_overflow || sx<0 || sy<0 || sx>MAX_X || sy>MAX_Y)begin
                        sample_valid<=0;wr_data<=0;state<=WRITE_HOLD;
                    end else begin
                        sample_valid<=1;
                        ix0=sx>>>16;iy0=sy>>>16;
                        ix1=ix0==SRC_WIDTH-1 ? ix0 : ix0+1;
                        iy1=iy0==SRC_HEIGHT-1 ? iy0 : iy0+1;
                        addresses[0]<=iy0*SRC_WIDTH+ix0;addresses[1]<=iy0*SRC_WIDTH+ix1;
                        addresses[2]<=iy1*SRC_WIDTH+ix0;addresses[3]<=iy1*SRC_WIDTH+ix1;
                        fx<=sx[15:0];fy<=sy[15:0];corner<=0;state<=READ_REQ;
                    end
                end
                READ_REQ: if(mem_req_ready)state<=READ_WAIT;
                READ_WAIT: if(mem_rsp_valid)begin
                    pixels[corner]<=mem_rsp_data;
                    if(corner==3)state<=INTERP;
                    else begin corner<=corner+1'b1;state<=READ_REQ;end
                end
                INTERP: state<=INTERP_WAIT;
                INTERP_WAIT: if(pixel_valid)begin wr_data<=pixel_value;state<=WRITE_HOLD;end
                WRITE_HOLD: if(wr_valid && wr_ready)begin
                    if(!sample_valid)invalid_pixels<=invalid_pixels+1;
                    if(sample_overflow)overflow_pixels<=overflow_pixels+1;
                    if(x==OUT_WIDTH-1 && y==OUT_HEIGHT-1)begin done<=1;state<=IDLE;end
                    else begin
                        index<=index+1'b1;
                        if(x==OUT_WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
                        state<=MAP_SEND;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
