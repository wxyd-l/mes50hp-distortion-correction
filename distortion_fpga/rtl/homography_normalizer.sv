`timescale 1ns/1ps
`default_nettype none
// Actual homogeneous division, no image-coordinate lookup table and no '/' cell.
// Matrix Q4.28; sum is shifted arithmetically to checked signed Q8.24.
// Two unsigned restoring dividers compute abs(n)<<24 / abs(z) in 56 steps.
// Quotients truncate toward zero. ce freezes token, remainder and all state.
// Configuration must be stable until the token retires (frame core latches it).
module homography_normalizer #(
    parameter integer POSITIVE_DEPTH=0
)(
    input wire clk,rst_n,ce,in_valid,
    output wire in_ready,
    input wire [15:0] in_u,in_v,
    input wire signed [31:0] a00,a01,a02,a10,a11,a12,a20,a21,a22,
    output wire out_valid,
    output reg out_overflow,
    output reg [15:0] out_u,out_v,
    output reg signed [31:0] norm_x,norm_y
);
    localparam IDLE=2'd0, ACC=2'd1, DIVIDE=2'd2, RESULT=2'd3;
    reg [1:0] state;
    reg signed [48:0] xu,xv,yu,yv,zu,zv;
    reg [55:0] nx,ny,qx,qy;
    reg [31:0] denominator;
    reg [32:0] rx,ry;
    reg sign_x,sign_y;
    reg [5:0] bits_left;
    function automatic signed [63:0] ext49(input reg signed [48:0] x);
        ext49={{15{x[48]}},x};
    endfunction
    function automatic signed [63:0] ext32(input reg signed [31:0] x);
        ext32={{32{x[31]}},x};
    endfunction
    function automatic overflow32(input reg signed [63:0] x);
        overflow32=x[63:31]!={33{x[31]}};
    endfunction
    function automatic [31:0] magnitude(input reg signed [31:0] x);
        magnitude=x[31] ? -x : x;
    endfunction
    wire signed [63:0] hx=(ext49(xu)+ext49(xv)+ext32(a02)) >>> 4;
    wire signed [63:0] hy=(ext49(yu)+ext49(yv)+ext32(a12)) >>> 4;
    wire signed [63:0] hz=(ext49(zu)+ext49(zv)+ext32(a22)) >>> 4;
    wire [32:0] tx={rx[31:0],nx[55]};
    wire [32:0] ty={ry[31:0],ny[55]};
    wire ge_x=tx>={1'b0,denominator};
    wire ge_y=ty>={1'b0,denominator};
    wire [55:0] next_qx={qx[54:0],ge_x};
    wire [55:0] next_qy={qy[54:0],ge_y};
    wire signed [63:0] signed_x=sign_x ? -$signed({8'd0,next_qx}) : $signed({8'd0,next_qx});
    wire signed [63:0] signed_y=sign_y ? -$signed({8'd0,next_qy}) : $signed({8'd0,next_qy});
    assign in_ready=ce && state==IDLE;
    assign out_valid=state==RESULT;
    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE; out_overflow<=0; norm_x<=0; norm_y<=0;
            out_u<=0;out_v<=0;
        end else if (ce) begin
            case(state)
                IDLE: if(in_valid) begin
                    xu<=a00*$signed({1'b0,in_u}); xv<=a01*$signed({1'b0,in_v});
                    yu<=a10*$signed({1'b0,in_u}); yv<=a11*$signed({1'b0,in_v});
                    zu<=a20*$signed({1'b0,in_u}); zv<=a21*$signed({1'b0,in_v});
                    out_u<=in_u;out_v<=in_v;out_overflow<=0;
                    state<=ACC;
                end
                ACC: begin
                    if (overflow32(hx)||overflow32(hy)||overflow32(hz)||hz==0||
                        (POSITIVE_DEPTH && hz<0)) begin
                        out_overflow<=1;norm_x<=0;norm_y<=0;state<=RESULT;
                    end else begin
                        nx<={magnitude(hx[31:0]),24'd0};ny<={magnitude(hy[31:0]),24'd0};
                        denominator<=magnitude(hz[31:0]);
                        sign_x<=hx[31]^hz[31];sign_y<=hy[31]^hz[31];
                        qx<=0;qy<=0;rx<=0;ry<=0;bits_left<=56;
                        state<=DIVIDE;
                    end
                end
                DIVIDE: begin
                    nx<={nx[54:0],1'b0};ny<={ny[54:0],1'b0};
                    rx<=ge_x ? tx-{1'b0,denominator} : tx;
                    ry<=ge_y ? ty-{1'b0,denominator} : ty;
                    qx<=next_qx;qy<=next_qy;bits_left<=bits_left-1'b1;
                    if(bits_left==1) begin
                        out_overflow<=overflow32(signed_x)||overflow32(signed_y);
                        norm_x<=overflow32(signed_x) ? 32'sd0 : signed_x[31:0];
                        norm_y<=overflow32(signed_y) ? 32'sd0 : signed_y[31:0];
                        state<=RESULT;
                    end
                end
                RESULT: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
