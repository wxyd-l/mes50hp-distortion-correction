`timescale 1ns/1ps
// Golden values come from Python, not from a duplicate Verilog implementation.
module tb_vectors;
    localparam W=64,H=48,N=W*H,CASES=4;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,ce=0,in_valid=0;
    reg [15:0] in_u=0,in_v=0;
    wire out_valid,out_overflow;
    wire [15:0] out_u,out_v;
    wire signed [31:0] src_x,src_y;
    reg [31:0] parameters_mem[0:69];
    reg [63:0] expected[0:CASES*N-1];
    integer test_case=0,tx=0,rx=0,cycles=0;
    reg [31:0] rng=32'hc0decafe;
    distortion_mapper dut(
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(in_valid),.in_u(in_u),.in_v(in_v),
        .a00(parameters_mem[test_case*14+0]),.a01(parameters_mem[test_case*14+1]),
        .a02(parameters_mem[test_case*14+2]),.a10(parameters_mem[test_case*14+3]),
        .a11(parameters_mem[test_case*14+4]),.a12(parameters_mem[test_case*14+5]),
        .k1(parameters_mem[test_case*14+6]),.k2(parameters_mem[test_case*14+7]),
        .p1(parameters_mem[test_case*14+8]),.p2(parameters_mem[test_case*14+9]),
        .fx(parameters_mem[test_case*14+10]),.fy(parameters_mem[test_case*14+11]),
        .cx(parameters_mem[test_case*14+12]),.cy(parameters_mem[test_case*14+13]),
        .out_valid(out_valid),.out_overflow(out_overflow),
        .out_u(out_u),.out_v(out_v),.src_x(src_x),.src_y(src_y));
    always @(posedge clk) if (rst_n && ce) begin
        if (in_valid) tx=tx+1;
        if (out_valid) begin
            if (rx>=N || out_u !== (rx%W) || out_v !== (rx/W))
                $fatal(1,"Vector ordering case=%0d rx=%0d u=%0d v=%0d",test_case,rx,out_u,out_v);
            if (out_overflow || {src_x,src_y} !== expected[test_case*N+rx])
                $fatal(1,"Vector mismatch case=%0d pixel=%0d got=%h expected=%h overflow=%b",
                    test_case,rx,{src_x,src_y},expected[test_case*N+rx],out_overflow);
            rx=rx+1;
        end
    end
    initial begin
        $readmemh("build/regression/parameters.mem",parameters_mem);
        $readmemh("build/regression/coordinates.mem",expected);
        repeat(4) @(negedge clk);
        for (test_case=0;test_case<CASES;test_case=test_case+1) begin
            rst_n=0; ce=0; in_valid=0;
            repeat(2) @(negedge clk);
            tx=0; rx=0; cycles=0; rst_n=1;
            while (rx<N) begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                ce=(rng[2:0]!=0);
                in_valid=(tx<N)&&(rng[5:3]!=0);
                in_u=tx%W; in_v=tx/W;
                @(negedge clk);
                cycles=cycles+1;
                if (cycles>20000) $fatal(1,"Vector timeout");
            end
            in_valid=0;
            $display("PASS coordinate case=%0d pixels=%0d cycles=%0d",test_case,rx,cycles);
        end
        $display("PASS tb_vectors: %0d independent Python/RTL coordinates",CASES*N);
        $finish;
    end
endmodule
