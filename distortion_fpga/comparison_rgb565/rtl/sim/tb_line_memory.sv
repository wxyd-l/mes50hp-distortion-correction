`timescale 1ns/1ps
// Test-only ordered line backend. Accepts one line at a time and pads the
// final line with zeros. Physical frame allocation MUST permit padded reads.
module tb_line_memory #(
    parameter PIXELS=805,ADDR_BITS=24,LINE_LOG2=4,SOURCE_FILE="",SEED=32'h7251,
    GENERATED=0
)(
    input logic clk,rst_n,
    input logic req_valid,
    output wire req_ready,
    input logic [ADDR_BITS-1:0] req_base,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [15:0] rsp_data,
    output logic rsp_last,
    input logic [15:0] generation,
    input logic [1:0] fault_mode
);
    localparam LP=1<<LINE_LOG2;
    reg [15:0] memory[0:PIXELS-1];
    reg [31:0] rng;
    reg active,held_req;
    reg [ADDR_BITS-1:0] base,held_base;
    integer offset,line_count,beat_count;
    initial if(!GENERATED)$readmemh(SOURCE_FILE,memory);
    assign req_ready=!active && !rsp_valid && rng[0];
    always @(posedge clk)begin
        if(!rst_n)begin
            rng<=SEED;active<=0;rsp_valid<=0;rsp_data<=0;rsp_last<=0;
            offset<=0;base<=0;line_count<=0;beat_count<=0;held_req<=0;held_base<=0;
        end else begin
            rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            if(held_req && (!req_valid || req_base!==held_base))$fatal(1,"line request changed while stalled");
            held_req<=req_valid && !req_ready;held_base<=req_base;
            if(req_valid && req_ready)begin
                if(req_base%LP || req_base>=PIXELS)$fatal(1,"line base outside allocated frame");
                active<=1;base<=req_base;offset<=0;line_count<=line_count+1;
            end
            if(active && !rsp_valid && rng[2])begin
                rsp_valid<=1;
                rsp_data<=GENERATED ? ((base+offset)*37)^16'h5a69^generation :
                           base+offset<PIXELS ? memory[base+offset] : 16'h0000;
                rsp_last<=fault_mode==1 ? offset==1 : fault_mode==2 ? 1'b0 : offset==LP-1;
            end
            if(rsp_valid && rsp_ready)begin
                rsp_valid<=0;beat_count<=beat_count+1;
                if(offset==LP-1 || rsp_last)begin active<=0;offset<=0;end
                else offset<=offset+1;
            end
        end
    end
endmodule
