`timescale 1ns/1ps
// Delay an entire token (data + validity + sync/tag) together, not DE alone.
module stream_delay #(parameter WIDTH=32, parameter STAGES=3)(
    input wire clk, rst_n, ce,
    input wire [WIDTH-1:0] in_token,
    output wire [WIDTH-1:0] out_token
);
    generate if (STAGES == 0) begin: bypass
        assign out_token = in_token;
    end else begin: delayed
        reg [WIDTH-1:0] pipe [0:STAGES-1];
        integer i;
        always @(posedge clk) begin
            if (!rst_n) begin
                for (i=0;i<STAGES;i=i+1) pipe[i] <= 0;
            end else if (ce) begin
                pipe[0] <= in_token;
                for (i=1;i<STAGES;i=i+1) pipe[i] <= pipe[i-1];
            end
        end
        assign out_token = pipe[STAGES-1];
    end endgenerate
endmodule
