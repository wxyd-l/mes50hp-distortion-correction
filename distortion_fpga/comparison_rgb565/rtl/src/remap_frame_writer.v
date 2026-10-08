`timescale 1ns/1ps
// Render an entire output frame to a write client. NOT an HDMI timing source.
// Source-frame storage must remain immutable until done; display the completed
// output through a separate read/display buffer, swapped safely by the adapter.
module remap_frame_writer #(
    parameter SRC_WIDTH=1280,SRC_HEIGHT=720,OUT_WIDTH=1280,OUT_HEIGHT=720,
    parameter GRID_LOG2=5,COORD_FRAC=8,WEIGHT_FRAC=16,ADDR_BITS=24,INIT_FILE="",USE_FAST_MAP=0
)(
    input wire clk,rst_n,start,
    output wire start_ready,
    output wire busy,
    output reg done,
    output reg [31:0] invalid_pixels,
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
    output wire [15:0] wr_data,
    input wire cfg_begin,cfg_we,cfg_commit,
    input wire [15:0] cfg_addr,
    input wire [63:0] cfg_data,
    output wire cfg_ready,cfg_error,pending,active_ready,active_bank
);
    localparam IDLE=0,BOUNDARY=1,SEND=2,WAIT_WRITE=3;
    reg [1:0] state;
    reg [15:0] x,y;
    reg [ADDR_BITS-1:0] write_index;
    wire engine_ready,engine_valid,engine_frame_ready,engine_error,sample_valid;
    assign busy=state!=IDLE;
    assign start_ready=state==IDLE && engine_frame_ready && (active_ready || pending);
    assign wr_valid=state==WAIT_WRITE && engine_valid;
    assign wr_addr=write_index;
    undistort_engine #(.SRC_WIDTH(SRC_WIDTH),.SRC_HEIGHT(SRC_HEIGHT),
        .OUT_WIDTH(OUT_WIDTH),.OUT_HEIGHT(OUT_HEIGHT),.GRID_LOG2(GRID_LOG2),
        .COORD_FRAC(COORD_FRAC),.WEIGHT_FRAC(WEIGHT_FRAC),.ADDR_BITS(ADDR_BITS),.INIT_FILE(INIT_FILE),.USE_FAST_MAP(USE_FAST_MAP)) engine (
        .clk(clk),.rst_n(rst_n),.in_valid(state==SEND),.in_ready(engine_ready),
        .dst_x(x),.dst_y(y),.in_sof(x==0 && y==0),.in_eol(x==OUT_WIDTH-1),
        .out_valid(engine_valid),.out_ready(state==WAIT_WRITE && wr_ready),.out_pixel(wr_data),
        .out_x(),.out_y(),.out_sof(),.out_eol(),.out_sample_valid(sample_valid),
        .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),.mem_req_addr(mem_req_addr),
        .mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),.mem_rsp_data(mem_rsp_data),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.active_ready(active_ready),.pending(pending),.active_bank(active_bank),
        .frame_start(state==BOUNDARY),.frame_ready(engine_frame_ready),.protocol_error(engine_error));
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;x<=0;y<=0;write_index<=0;done<=0;invalid_pixels<=0;protocol_error<=0;
        end else begin
            done<=0;
            if(engine_error || (start && !start_ready)) protocol_error<=1;
            case(state)
                IDLE: if(start && start_ready) begin
                    x<=0;y<=0;write_index<=0;invalid_pixels<=0;state<=BOUNDARY;
                end
                BOUNDARY: state<=SEND;
                SEND: if(engine_ready) state<=WAIT_WRITE;
                WAIT_WRITE: if(wr_valid && wr_ready) begin
                    if(!sample_valid) invalid_pixels<=invalid_pixels+1;
                    if(x==OUT_WIDTH-1 && y==OUT_HEIGHT-1) begin done<=1;state<=IDLE;end
                    else begin
                        write_index<=write_index+1'b1;
                        if(x==OUT_WIDTH-1) begin x<=0;y<=y+1'b1;end
                        else x<=x+1'b1;
                        state<=SEND;
                    end
                end
            endcase
        end
    end
endmodule
