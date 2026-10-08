`timescale 1ns/1ps
`include "formula_parameters.vh"
// Small package: every coordinate under continuous and global-CE stalls.
module tb_formula_mapper;
    localparam W=`FORMULA_W,H=`FORMULA_H,N=W*H;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=0,in_valid=0;
    reg [15:0] u=0,v=0;
    reg [447:0] configuration[0:0];
    wire valid,overflow;
    wire [15:0] out_u,out_v;
    wire signed [31:0] sx,sy;
    reg [31:0] expected_x[0:N-1],expected_y[0:N-1];
    brown_mapper_pipeline dut(
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(in_valid),.in_u(u),.in_v(v),
        .a00(configuration[0][0*32+:32]),.a01(configuration[0][1*32+:32]),.a02(configuration[0][2*32+:32]),
        .a10(configuration[0][3*32+:32]),.a11(configuration[0][4*32+:32]),.a12(configuration[0][5*32+:32]),
        .k1(configuration[0][6*32+:32]),.k2(configuration[0][7*32+:32]),
        .p1(configuration[0][8*32+:32]),.p2(configuration[0][9*32+:32]),
        .fx(configuration[0][10*32+:32]),.fy(configuration[0][11*32+:32]),
        .cx(configuration[0][12*32+:32]),.cy(configuration[0][13*32+:32]),
        .out_valid(valid),.out_overflow(overflow),.out_u(out_u),.out_v(out_v),.src_x(sx),.src_y(sy));
    integer sent,received,cycles,enabled,mode;
    reg [31:0] rng=32'h4d657331;
    reg [97:0] snapshot;
    initial begin
        $readmemh("parameters.memh",configuration);$readmemh("expected_x.memh",expected_x);$readmemh("expected_y.memh",expected_y);
        for(mode=0;mode<2;mode=mode+1)begin
            @(negedge clk);rst_n=0;ce=0;in_valid=0;
            repeat(3)@(posedge clk);
            @(negedge clk);rst_n=1;
            sent=0;received=0;cycles=0;enabled=0;
            while(received<N)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                ce=mode==0 ? 1 : rng[0];in_valid=sent<N;u=sent%W;v=sent/W;
                snapshot={valid,overflow,out_u,out_v,sx,sy};
                @(posedge clk);#1;cycles=cycles+1;
                if(ce)begin
                    enabled=enabled+1;
                    if(in_valid)sent=sent+1;
                    if(valid)begin
                        if(out_u!==received%W || out_v!==received/W || sx!==expected_x[received] ||
                           sy!==expected_y[received] || overflow!==(`FORMULA_OVERFLOW!=0))
                            $fatal(1,"formula pipeline token mismatch %0d",received);
                        received=received+1;
                    end
                end else if({valid,overflow,out_u,out_v,sx,sy}!==snapshot)$fatal(1,"formula pipeline changed with CE off");
                if(cycles>N*10+100)$fatal(1,"formula mapper timeout");
                @(negedge clk);
            end
            if(enabled!=N+11)$fatal(1,"formula mapper latency was not 12 enabled stages");
            $display("FORMULA_MAPPER_PASSED mode=%0d tokens=%0d enabled=%0d cycles=%0d",mode,received,enabled,cycles);
        end
        $finish;
    end
endmodule
