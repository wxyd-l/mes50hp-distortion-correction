`timescale 1ns/1ps
// One-outstanding direct-mapped read-only cache. 32-byte lines contain eight
// 32-bit pixel slots, each carrying RGB888 in bits [23:0]. Byte addresses.
// Data/tag memories are synchronously read and are never reset. Only valid bits
// are cleared. Source-frame ownership must change only after invalidate accepts.
// Reset requires the downstream adapter to flush its pending transaction too.
module pixel_read_cache #(
    parameter integer LINES = 512
)(
    input wire clk,
    input wire rst_n,
    input wire invalidate,
    output wire invalidate_ready,
    input wire req_valid,
    output wire req_ready,
    input wire [31:0] req_addr,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg [31:0] rsp_data,
    output reg [2:0] rsp_error,
    output wire line_req_valid,
    input wire line_req_ready,
    output wire [31:0] line_req_addr,
    input wire line_rsp_valid,
    output wire line_rsp_ready,
    input wire [255:0] line_rsp_data,
    input wire [2:0] line_rsp_error,
    output reg [31:0] hit_count,
    output reg [31:0] miss_count
);
    localparam integer LOG_LINES = $clog2(LINES);
    localparam integer INDEX_BITS = LOG_LINES > 0 ? LOG_LINES : 1;
    localparam integer TAG_BITS = 27-LOG_LINES;
    localparam [2:0] IDLE=0, LOOKUP=1, SEND_LINE=2, WAIT_LINE=3, RESPONSE=4;
    reg [2:0] state;
    reg [255:0] data_mem [0:LINES-1];
    reg [TAG_BITS-1:0] tag_mem [0:LINES-1];
    reg [LINES-1:0] valid_bits;
    reg [255:0] read_line;
    reg [TAG_BITS-1:0] read_tag;
    reg read_valid;
    wire [INDEX_BITS-1:0] request_index = (req_addr >> 5) & (LINES-1);
    wire [TAG_BITS-1:0] request_tag = req_addr >> (5+LOG_LINES);
    reg [INDEX_BITS-1:0] saved_index;
    reg [TAG_BITS-1:0] saved_tag;
    reg [2:0] saved_word;
    reg [31:0] saved_line_addr;

    assign invalidate_ready = rst_n && state == IDLE;
    assign req_ready = rst_n && state == IDLE && !invalidate;
    assign rsp_valid = rst_n && state == RESPONSE;
    assign line_req_valid = rst_n && state == SEND_LINE;
    assign line_req_addr = saved_line_addr;
    assign line_rsp_ready = rst_n && state == WAIT_LINE;

    // synthesis translate_off
    initial begin
        if (LINES < 1 || (LINES & (LINES-1)) != 0 || LOG_LINES > 20)
            $fatal(1,"LINES must be a positive power of two <= 2**20");
    end
    // synthesis translate_on

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            valid_bits <= {LINES{1'b0}};
            hit_count <= 0;
            miss_count <= 0;
            rsp_data <= 0;
            rsp_error <= 0;
            saved_line_addr <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (invalidate) begin
                        valid_bits <= {LINES{1'b0}};
                    end else if (req_valid) begin
                        rsp_data <= 0;
                        rsp_error <= 0;
                        if (req_addr[1:0] != 0) begin
                            rsp_error <= 3'b001;
                            state <= RESPONSE;
                        end else if (req_addr[31:30] != 0) begin
                            rsp_error <= 3'b010;
                            state <= RESPONSE;
                        end else begin
                            saved_index <= request_index;
                            saved_tag <= request_tag;
                            saved_word <= req_addr[4:2];
                            saved_line_addr <= {req_addr[31:5],5'b0};
                            read_line <= data_mem[request_index];
                            read_tag <= tag_mem[request_index];
                            read_valid <= valid_bits[request_index];
                            state <= LOOKUP;
                        end
                    end
                end
                LOOKUP: begin
                    if (read_valid && read_tag == saved_tag) begin
                        hit_count <= hit_count+1;
                        rsp_data <= read_line[saved_word*32 +: 32];
                        state <= RESPONSE;
                    end else begin
                        miss_count <= miss_count+1;
                        state <= SEND_LINE;
                    end
                end
                SEND_LINE: if (line_req_ready) state <= WAIT_LINE;
                WAIT_LINE: if (line_rsp_valid) begin
                    rsp_error <= line_rsp_error;
                    if (line_rsp_error == 0) begin
                        data_mem[saved_index] <= line_rsp_data;
                        tag_mem[saved_index] <= saved_tag;
                        valid_bits[saved_index] <= 1'b1;
                        rsp_data <= line_rsp_data[saved_word*32 +: 32];
                    end else begin
                        // A failed conflicting read preserves the previous line.
                        rsp_data <= 0;
                    end
                    state <= RESPONSE;
                end
                RESPONSE: if (rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
