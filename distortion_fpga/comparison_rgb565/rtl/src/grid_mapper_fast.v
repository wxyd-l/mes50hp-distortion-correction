`timescale 1ns/1ps
// Five enabled-edge stages: address/weights, synchronous ROM, three math stages.
// Accepts one pixel each clock when the sink is ready. One global CE stalls all
// stages so ordering/data are preserved. Four replicated dual-bank LUTs provide
// four simultaneous registered reads; this trades memory for throughput.
module grid_mapper_fast #(
    parameter OUT_WIDTH=1280,OUT_HEIGHT=720,
    parameter GRID_LOG2=5,COORD_FRAC=8,WEIGHT_FRAC=16,INIT_FILE=""
)(
    input wire clk,rst_n,in_valid,
    output wire in_ready,
    input wire [15:0] dst_x,dst_y,
    output wire out_valid,
    input wire out_ready,
    output wire signed [31:0] src_x_q,src_y_q,
    input wire cfg_begin,cfg_we,cfg_commit,
    input wire [15:0] cfg_addr,
    input wire [63:0] cfg_data,
    output wire cfg_ready,cfg_error,active_ready,pending,active_bank,
    input wire frame_start,
    output wire frame_ready
);
    localparam STEP=1<<GRID_LOG2;
    localparam COLS=((OUT_WIDTH-1+STEP-1)/STEP)+1;
    localparam ROWS=((OUT_HEIGHT-1+STEP-1)/STEP)+1;
    localparam LAST_X=(OUT_WIDTH-1)-(COLS-2)*STEP;
    localparam LAST_Y=(OUT_HEIGHT-1)-(ROWS-2)*STEP;
    // synthesis translate_off
    initial begin
        if(OUT_WIDTH<2 || OUT_HEIGHT<2 || OUT_WIDTH>65535 || OUT_HEIGHT>65535)
            $fatal(1,"output dimensions must be in [2,65535]");
        if(GRID_LOG2<0 || GRID_LOG2>14 || COLS*ROWS>65536)
            $fatal(1,"grid exceeds shift/address limits");
        if((WEIGHT_FRAC!=8 && WEIGHT_FRAC!=16) || COORD_FRAC<1 || COORD_FRAC>16)
            $fatal(1,"unsupported fixed-point precision");
    end
    // synthesis translate_on
    reg v0,v1,invalid0,invalid1;
    reg [15:0] base0;
    reg [WEIGHT_FRAC:0] wx0,wy0,wx1,wy1;
    reg [3:0] in_flight;
    wire ce=!out_valid || out_ready;
    assign in_ready=ce && active_ready && !frame_start;
    assign frame_ready=in_flight==0;
    wire accepted_frame=frame_start && frame_ready;
    wire [63:0] node00,node10,node01,node11;
    wire [15:0] address10=base0+1;
    wire [15:0] address01=base0+COLS;
    wire [15:0] address11=base0+COLS+1;
    wire read_enable=ce && v0 && !invalid0;
    map_lut #(.NODES(COLS*ROWS),.INIT_FILE(INIT_FILE)) rom00(
        .clk(clk),.rst_n(rst_n),.rd_en(read_enable),.rd_addr(base0),.rd_data(node00),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.active_ready(active_ready),.pending(pending),
        .frame_start(accepted_frame),.active_bank(active_bank));
    map_lut #(.NODES(COLS*ROWS),.INIT_FILE(INIT_FILE)) rom10(
        .clk(clk),.rst_n(rst_n),.rd_en(read_enable),.rd_addr(address10),.rd_data(node10),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(),.cfg_error(),.active_ready(),.pending(),.frame_start(accepted_frame),.active_bank());
    map_lut #(.NODES(COLS*ROWS),.INIT_FILE(INIT_FILE)) rom01(
        .clk(clk),.rst_n(rst_n),.rd_en(read_enable),.rd_addr(address01),.rd_data(node01),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(),.cfg_error(),.active_ready(),.pending(),.frame_start(accepted_frame),.active_bank());
    map_lut #(.NODES(COLS*ROWS),.INIT_FILE(INIT_FILE)) rom11(
        .clk(clk),.rst_n(rst_n),.rd_en(read_enable),.rd_addr(address11),.rd_data(node11),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(),.cfg_error(),.active_ready(),.pending(),.frame_start(accepted_frame),.active_bank());
    bilinear_signed #(.DATA_BITS(32),.FRAC_BITS(WEIGHT_FRAC)) x_math(
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(v1),
        .a00(invalid1 ? -32'sd1 : $signed(node00[31:0])),.a10(invalid1 ? -32'sd1 : $signed(node10[31:0])),
        .a01(invalid1 ? -32'sd1 : $signed(node01[31:0])),.a11(invalid1 ? -32'sd1 : $signed(node11[31:0])),
        .wx(wx1),.wy(wy1),.out_valid(out_valid),.out_value(src_x_q));
    bilinear_signed #(.DATA_BITS(32),.FRAC_BITS(WEIGHT_FRAC)) y_math(
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(v1),
        .a00(invalid1 ? -32'sd1 : $signed(node00[63:32])),.a10(invalid1 ? -32'sd1 : $signed(node10[63:32])),
        .a01(invalid1 ? -32'sd1 : $signed(node01[63:32])),.a11(invalid1 ? -32'sd1 : $signed(node11[63:32])),
        .wx(wx1),.wy(wy1),.out_valid(),.out_value(src_y_q));
    integer cx,cy,ox,oy;
    always @(posedge clk) begin
        if(!rst_n) begin
            v0<=0;v1<=0;invalid0<=0;invalid1<=0;base0<=0;
            wx0<=0;wy0<=0;wx1<=0;wy1<=0;in_flight<=0;
        end else begin
            case({in_valid && in_ready,out_valid && out_ready})
                2'b10:in_flight<=in_flight+1'b1;
                2'b01:in_flight<=in_flight-1'b1;
            endcase
            if(ce) begin
                v0<=in_valid && in_ready;
                v1<=v0;invalid1<=invalid0;wx1<=wx0;wy1<=wy0;
                if(in_valid && in_ready)begin
                    invalid0<=dst_x>=OUT_WIDTH || dst_y>=OUT_HEIGHT;
                    if(dst_x>=OUT_WIDTH || dst_y>=OUT_HEIGHT)begin base0<=0;wx0<=0;wy0<=0;end
                    else begin
                        cx=dst_x>>GRID_LOG2;cy=dst_y>>GRID_LOG2;
                        if(cx>=COLS-1)cx=COLS-2;if(cy>=ROWS-1)cy=ROWS-2;
                        ox=dst_x-cx*STEP;oy=dst_y-cy*STEP;base0<=cy*COLS+cx;
                        if(cx==COLS-2)wx0<=((ox<<WEIGHT_FRAC)+LAST_X/2)/LAST_X;
                        else wx0<=((ox<<WEIGHT_FRAC)+STEP/2)/STEP;
                        if(cy==ROWS-2)wy0<=((oy<<WEIGHT_FRAC)+LAST_Y/2)/LAST_Y;
                        else wy0<=((oy<<WEIGHT_FRAC)+STEP/2)/STEP;
                    end
                end
            end
        end
    end
endmodule
