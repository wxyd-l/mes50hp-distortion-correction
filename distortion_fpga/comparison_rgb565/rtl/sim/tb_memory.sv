`timescale 1ns/1ps
// Test-only pixel memory: random request stalls and multi-cycle responses.
module tb_memory #(parameter WIDTH=35,HEIGHT=23,SOURCE_FILE="vectors/source.memh",SEED=32'h19beef)(
    input logic clk,rst_n,
    input logic req_valid,
    output wire req_ready,
    input logic [23:0] req_addr,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [15:0] rsp_data
);
    reg [15:0] memory [0:WIDTH*HEIGHT-1];
    reg [31:0] rng;
    reg outstanding;
    reg [23:0] address;
    integer delay_left;
    integer read_count;
    reg held_request;
    reg [23:0] held_request_addr;
    initial $readmemh(SOURCE_FILE,memory);
    assign req_ready=!outstanding && !rsp_valid && rng[0];
    always @(posedge clk) begin
        if(!rst_n) begin
            rng<=SEED;outstanding<=0;rsp_valid<=0;rsp_data<=0;address<=0;delay_left<=0;
            read_count<=0;held_request<=0;held_request_addr<=0;
        end else begin
            if(held_request && (!req_valid || req_addr!==held_request_addr))
                $fatal(1,"memory request changed while stalled");
            held_request<=req_valid && !req_ready;held_request_addr<=req_addr;
            rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            if(req_valid && req_ready) begin
                if(req_addr>=WIDTH*HEIGHT) $fatal(1,"out-of-range read address %d",req_addr);
                address<=req_addr;outstanding<=1;delay_left<=1+rng[3:1];
                read_count<=read_count+1;
            end
            if(outstanding) begin
                if(delay_left==0) begin rsp_data<=memory[address];rsp_valid<=1;outstanding<=0;end
                else delay_left<=delay_left-1;
            end
            if(rsp_valid && rsp_ready) rsp_valid<=0;
        end
    end
endmodule
