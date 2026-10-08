`timescale 1ns/1ps
// One enabled-cycle static per-channel Gamma stage. Black remains black when
// generated tables are used. META_BITS carries tags/coordinates with the pixel.
// Keep enable stable for a whole frame. File paths are elaboration parameters,
// not an implemented UART configuration protocol. Empty files mean identity.
module gamma_rgb565 #(
    parameter META_BITS=1,
    parameter LUT5_FILE="",LUT6_FILE=""
)(
    input wire clk,rst_n,ce,in_valid,enable,
    input wire [15:0] in_pixel,
    input wire [META_BITS-1:0] in_meta,
    output reg out_valid,
    output reg [15:0] out_pixel,
    output reg [META_BITS-1:0] out_meta
);
    reg [4:0] lut5 [0:31];
    reg [5:0] lut6 [0:63];
    integer i;
    initial begin
        for(i=0;i<32;i=i+1) lut5[i]=i;
        for(i=0;i<64;i=i+1) lut6[i]=i;
        if(LUT5_FILE!="") $readmemh(LUT5_FILE,lut5);
        if(LUT6_FILE!="") $readmemh(LUT6_FILE,lut6);
    end
    always @(posedge clk) begin
        if(!rst_n) begin out_valid<=0;out_pixel<=0;out_meta<=0;end
        else if(ce) begin
            out_valid<=in_valid;out_meta<=in_meta;
            if(enable) out_pixel<={lut5[in_pixel[15:11]],lut6[in_pixel[10:5]],lut5[in_pixel[4:0]]};
            else out_pixel<=in_pixel;
        end
    end
endmodule
