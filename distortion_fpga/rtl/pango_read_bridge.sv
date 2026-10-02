`timescale 1ns/1ps
// MES50HP x32 DDR3_50H read-port bridge: exactly one 32-byte beat.
// addr units at the vendor port are 32-bit words, not AXI byte addresses.
// No rready exists: reserve our complete response register before issuing AR.
// Synchronous reset MUST flush the vendor transaction too, or upstream must
// hold this bridge in reset until all pre-reset returns have been drained.
// Error bits: [0] unaligned, [1] beyond 1 GiB, [2] RID/RLAST protocol error.
module pango_read_bridge (
    input wire clk, input wire rst_n,
    input wire req_valid, output wire req_ready,
    input wire [31:0] req_addr,
    output wire rsp_valid, input wire rsp_ready,
    output reg [255:0] rsp_data,
    output reg [2:0] rsp_error,
    output reg protocol_error,
    output reg [27:0] axi_araddr,
    output wire [3:0] axi_arlen,
    output wire [3:0] axi_arid,
    output wire axi_arvalid, input wire axi_arready,
    input wire [255:0] axi_rdata,
    input wire [3:0] axi_rid,
    input wire axi_rvalid, input wire axi_rlast
);
    localparam IDLE=2'd0, ISSUE=2'd1, WAIT_R=2'd2, RESPONSE=2'd3;
    reg [1:0] state;
    wire address_bad_align = |req_addr[4:0];
    wire address_bad_range = |req_addr[31:30];
    wire expecting_return = (state == WAIT_R) || ((state == ISSUE) && axi_arready);
    wire bad_return = (axi_rid != 4'd0) || !axi_rlast;
    assign req_ready = rst_n && (state == IDLE);
    assign rsp_valid = rst_n && (state == RESPONSE);
    assign axi_arvalid = rst_n && (state == ISSUE);
    assign axi_arlen = 4'd0;
    assign axi_arid = 4'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            rsp_data <= 0;
            rsp_error <= 0;
            protocol_error <= 0;
            axi_araddr <= 0;
        end else begin
            // Includes duplicate, unsolicited, and premature returns. Such data
            // never overwrites a response held under downstream backpressure.
            if (axi_rvalid && (!expecting_return || bad_return))
                protocol_error <= 1'b1;
            case (state)
                IDLE: if (req_valid) begin
                    rsp_error <= {1'b0, address_bad_range, address_bad_align};
                    if (address_bad_align || address_bad_range) begin
                        rsp_data <= 0;
                        state <= RESPONSE;
                    end else begin
                        axi_araddr <= req_addr[29:2];
                        state <= ISSUE;
                    end
                end
                ISSUE: if (axi_arready) begin
                    if (axi_rvalid) begin
                        rsp_data <= axi_rdata;
                        rsp_error <= {bad_return, 2'b00};
                        state <= RESPONSE;
                    end else state <= WAIT_R;
                end
                WAIT_R: if (axi_rvalid) begin
                    rsp_data <= axi_rdata;
                    rsp_error <= {bad_return, 2'b00};
                    state <= RESPONSE;
                end
                RESPONSE: if (rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
