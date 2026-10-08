`timescale 1ns/1ps
// Two-way read-only blocking cache. Frontend addresses count RGB565 pixels.
// Backend requests ONE aligned line, then accepts LINE_PIXELS ordered 16-bit
// beats, last ONLY on the final beat. This is NOT a physical DDR/AXI interface.
// Source frame must remain immutable. Invalidate at an idle frame boundary;
// reset cache AND backend together to cancel any stale responses.
module rgb565_read_cache #(
    parameter ADDR_BITS=24,LINE_LOG2=4,SET_LOG2=9
)(
    input wire clk,rst_n,
    input wire req_valid,
    output wire req_ready,
    input wire [ADDR_BITS-1:0] req_addr,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg [15:0] rsp_data,
    input wire invalidate_valid,
    output wire invalidate_ready,
    output wire busy,
    output wire line_req_valid,
    input wire line_req_ready,
    output wire [ADDR_BITS-1:0] line_req_base_addr,
    input wire line_rsp_valid,
    output wire line_rsp_ready,
    input wire [15:0] line_rsp_data,
    input wire line_rsp_last,
    output reg protocol_error,
    output reg [31:0] request_count,hit_count,miss_count,fill_beat_count
);
    localparam SETS=1<<SET_LOG2,LINE_PIXELS=1<<LINE_LOG2;
    localparam TAG_BITS=ADDR_BITS-SET_LOG2-LINE_LOG2;
    localparam IDLE=0,LOOKUP=1,LINE_REQ=2,FILL=3,HOLD=4,FAULT=5;
    reg [2:0] state;
    reg [ADDR_BITS-1:0] address;
    reg [TAG_BITS-1:0] tags0[0:SETS-1],tags1[0:SETS-1];
    reg valid0[0:SETS-1],valid1[0:SETS-1],most_recent_way[0:SETS-1];
    reg [15:0] data[0:2*SETS*LINE_PIXELS-1];
    reg victim;
    reg [LINE_LOG2-1:0] fill_offset;
    reg [15:0] selected_word;
    wire [SET_LOG2-1:0] set_index=address[LINE_LOG2+SET_LOG2-1:LINE_LOG2];
    wire [LINE_LOG2-1:0] offset=address[LINE_LOG2-1:0];
    wire [TAG_BITS-1:0] tag=address[ADDR_BITS-1:LINE_LOG2+SET_LOG2];
    wire hit0=valid0[set_index] && tags0[set_index]==tag;
    wire hit1=valid1[set_index] && tags1[set_index]==tag;
    wire chosen_victim=!valid0[set_index] ? 1'b0 : !valid1[set_index] ? 1'b1 : !most_recent_way[set_index];
    integer i;
    assign req_ready=rst_n && state==IDLE && !invalidate_valid;
    assign rsp_valid=rst_n && state==HOLD;
    assign invalidate_ready=rst_n && state==IDLE;
    assign busy=rst_n && state!=IDLE;
    assign line_req_valid=rst_n && state==LINE_REQ;
    assign line_req_base_addr={address[ADDR_BITS-1:LINE_LOG2],{LINE_LOG2{1'b0}}};
    assign line_rsp_ready=rst_n && state==FILL;
    // synthesis translate_off
    initial begin
        if(ADDR_BITS<3 || ADDR_BITS>30 || LINE_LOG2<1 || LINE_LOG2>8 || SET_LOG2<1 || SET_LOG2>14 || TAG_BITS<1)
            $fatal(1,"unsupported cache address/line/set widths");
    end
    // synthesis translate_on
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;address<=0;victim<=0;fill_offset<=0;selected_word<=0;rsp_data<=0;
            protocol_error<=0;request_count<=0;hit_count<=0;miss_count<=0;fill_beat_count<=0;
            for(i=0;i<SETS;i=i+1)begin valid0[i]<=0;valid1[i]<=0;most_recent_way[i]<=0;end
        end else if(line_rsp_valid && state!=FILL) begin
            // Fail closed on an unsolicited response. Recover by joint reset.
            protocol_error<=1;state<=FAULT;
        end else begin
            case(state)
                IDLE: begin
                    if(invalidate_valid) begin
                        for(i=0;i<SETS;i=i+1)begin valid0[i]<=0;valid1[i]<=0;most_recent_way[i]<=0;end
                        request_count<=0;hit_count<=0;miss_count<=0;fill_beat_count<=0;
                    end else if(req_valid) begin
                        address<=req_addr;request_count<=request_count+1'b1;state<=LOOKUP;
                    end
                end
                LOOKUP: begin
                    if(hit0 || hit1)begin
                        // A synchronous data-array read; no combinational pixel RAM output.
                        rsp_data<=data[(set_index*2+(hit0 ? 0 : 1))*LINE_PIXELS+offset];
                        most_recent_way[set_index]<=hit0 ? 1'b0 : 1'b1;
                        hit_count<=hit_count+1'b1;state<=HOLD;
                    end else begin
                        victim<=chosen_victim;
                        if(chosen_victim)valid1[set_index]<=0;else valid0[set_index]<=0;
                        fill_offset<=0;selected_word<=0;miss_count<=miss_count+1'b1;state<=LINE_REQ;
                    end
                end
                LINE_REQ: if(line_req_ready)state<=FILL;
                FILL: if(line_rsp_valid)begin
                    fill_beat_count<=fill_beat_count+1'b1;
                    if(line_rsp_last!=(fill_offset==LINE_PIXELS-1))begin
                        protocol_error<=1;state<=FAULT;
                    end else begin
                        data[(set_index*2+victim)*LINE_PIXELS+fill_offset]<=line_rsp_data;
                        if(fill_offset==offset)selected_word<=line_rsp_data;
                        if(fill_offset==LINE_PIXELS-1)begin
                            if(victim)begin tags1[set_index]<=tag;valid1[set_index]<=1;end
                            else begin tags0[set_index]<=tag;valid0[set_index]<=1;end
                            most_recent_way[set_index]<=victim;
                            rsp_data<=fill_offset==offset ? line_rsp_data : selected_word;
                            state<=HOLD;
                        end else fill_offset<=fill_offset+1'b1;
                    end
                end
                HOLD: if(rsp_ready)state<=IDLE;
                FAULT: state<=FAULT;
                default: begin protocol_error<=1;state<=FAULT;end
            endcase
        end
    end
endmodule
