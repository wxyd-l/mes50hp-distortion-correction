`timescale 1ns/1ps
// Correctness-first multicycle mapper: four synchronous LUT reads for each token.
// It is NOT a one-pixel-per-clock video filter. Valid/ready makes stalls explicit.
module grid_mapper #(
    parameter OUT_WIDTH=1280, OUT_HEIGHT=720,
    parameter GRID_LOG2=5, COORD_FRAC=8, WEIGHT_FRAC=16,
    parameter INIT_FILE=""
)(
    input wire clk, rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire [15:0] dst_x,dst_y,
    output reg out_valid,
    input wire out_ready,
    output reg signed [31:0] src_x_q,src_y_q,
    input wire cfg_begin,cfg_we,cfg_commit,
    input wire [15:0] cfg_addr,
    input wire [63:0] cfg_data,
    output wire cfg_ready,cfg_error,active_ready,pending,
    input wire frame_start,
    output wire frame_ready,
    output wire active_bank
);
    localparam STEP=(1<<GRID_LOG2);
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
        if(WEIGHT_FRAC!=8 && WEIGHT_FRAC!=16)
            $fatal(1,"supported grid weight precision is 8 or 16 bits");
        if(COORD_FRAC<1 || COORD_FRAC>16)
            $fatal(1,"coordinate fraction must be in [1,16]");
    end
    // synthesis translate_on
    localparam IDLE=0, ISSUE=1, CAPTURE=2, LAUNCH=3, WAIT_MATH=4, HOLD=5;
    reg [2:0] state;
    reg [1:0] corner;
    reg [15:0] base_addr;
    reg [WEIGHT_FRAC:0] wx,wy;
    reg signed [31:0] x00,x10,x01,x11,y00,y10,y01,y11;
    integer cell_x,cell_y,offset_x,offset_y;
    wire rd_en = state==ISSUE;
    wire [15:0] rd_addr = base_addr + ((corner[1]) ? COLS : 0) + corner[0];
    wire [63:0] rd_data;
    wire math_valid;
    wire signed [31:0] math_x,math_y;
    wire accepted_frame = frame_start && frame_ready;
    assign in_ready = state==IDLE && active_ready && !frame_start;
    assign frame_ready = state==IDLE;
    map_lut #(.NODES(COLS*ROWS),.INIT_FILE(INIT_FILE)) lut (
        .clk(clk),.rst_n(rst_n),.rd_en(rd_en),.rd_addr(rd_addr),.rd_data(rd_data),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),
        .cfg_addr(cfg_addr),.cfg_data(cfg_data),.cfg_ready(cfg_ready),.cfg_error(cfg_error),
        .frame_start(accepted_frame),.active_bank(active_bank),.active_ready(active_ready),.pending(pending));
    bilinear_signed #(.DATA_BITS(32),.FRAC_BITS(WEIGHT_FRAC)) x_math (
        .clk(clk),.rst_n(rst_n),.ce(1'b1),.in_valid(state==LAUNCH),
        .a00(x00),.a10(x10),.a01(x01),.a11(x11),.wx(wx),.wy(wy),
        .out_valid(math_valid),.out_value(math_x));
    bilinear_signed #(.DATA_BITS(32),.FRAC_BITS(WEIGHT_FRAC)) y_math (
        .clk(clk),.rst_n(rst_n),.ce(1'b1),.in_valid(state==LAUNCH),
        .a00(y00),.a10(y10),.a01(y01),.a11(y11),.wx(wx),.wy(wy),
        .out_valid(),.out_value(math_y));
    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE; corner<=0; base_addr<=0; wx<=0; wy<=0;
            x00<=0;x10<=0;x01<=0;x11<=0;y00<=0;y10<=0;y01<=0;y11<=0;
            out_valid<=0; src_x_q<=0; src_y_q<=0;
        end else case(state)
            IDLE: if(in_valid && in_ready) begin
                if (dst_x >= OUT_WIDTH || dst_y >= OUT_HEIGHT) begin
                    src_x_q<=-1;src_y_q<=-1;out_valid<=1;state<=HOLD;
                end else begin
                cell_x=dst_x>>GRID_LOG2; cell_y=dst_y>>GRID_LOG2;
                if(cell_x>=COLS-1) cell_x=COLS-2;
                if(cell_y>=ROWS-1) cell_y=ROWS-2;
                offset_x=dst_x-cell_x*STEP; offset_y=dst_y-cell_y*STEP;
                // Quantize fractions nearest/ties up; only final-cell divisors
                // differ from a power of two. Endpoints can equal 2**WEIGHT_FRAC.
                if(cell_x==COLS-2) wx<=((offset_x<<WEIGHT_FRAC)+LAST_X/2)/LAST_X;
                else wx<=((offset_x<<WEIGHT_FRAC)+STEP/2)/STEP;
                if(cell_y==ROWS-2) wy<=((offset_y<<WEIGHT_FRAC)+LAST_Y/2)/LAST_Y;
                else wy<=((offset_y<<WEIGHT_FRAC)+STEP/2)/STEP;
                base_addr<=cell_y*COLS+cell_x;
                corner<=0; state<=ISSUE;
                end
            end
            ISSUE: state<=CAPTURE;
            CAPTURE: begin
                case(corner)
                    0: begin x00<=rd_data[31:0];y00<=rd_data[63:32];end
                    1: begin x10<=rd_data[31:0];y10<=rd_data[63:32];end
                    2: begin x01<=rd_data[31:0];y01<=rd_data[63:32];end
                    3: begin x11<=rd_data[31:0];y11<=rd_data[63:32];end
                endcase
                if(corner==3) state<=LAUNCH;
                else begin corner<=corner+1'b1;state<=ISSUE;end
            end
            LAUNCH: state<=WAIT_MATH;
            WAIT_MATH: if(math_valid) begin
                src_x_q<=math_x;src_y_q<=math_y;out_valid<=1;state<=HOLD;
            end
            HOLD: if(out_valid && out_ready) begin out_valid<=0;state<=IDLE;end
            default: state<=IDLE;
        endcase
    end
endmodule
