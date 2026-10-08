`timescale 1ns/1ps
`include "settings.vh"
module tb_fast_mapper;
    localparam N=`TEST_NODES,C=`QUERY_CASES;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,out_ready=0,frame_start=0,cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [15:0] x=0,y=0,cfg_addr=0;reg [63:0] cfg_data=0;
    wire in_ready,out_valid,frame_ready,cfg_ready,cfg_error,active_ready,pending,bank;
    wire signed [31:0] sx,sy;
    reg [95:0] map0[0:C-1],map1[0:C-1];reg [63:0] lut0[0:N-1],lut1[0:N-1];
    reg [31:0] rng=32'h17345;
    grid_mapper_fast #(.OUT_WIDTH(`TEST_WIDTH),.OUT_HEIGHT(`TEST_HEIGHT),
        .GRID_LOG2(`TEST_LOG2),.WEIGHT_FRAC(`TEST_WEIGHT_FRAC)) dut(
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),.dst_x(x),.dst_y(y),
        .out_valid(out_valid),.out_ready(out_ready),.src_x_q(sx),.src_y_q(sy),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.active_ready(active_ready),.pending(pending),
        .frame_start(frame_start),.frame_ready(frame_ready),.active_bank(bank));
    task reset_dut;
        @(negedge clk);rst_n=0;in_valid=0;out_ready=0;frame_start=0;cfg_begin=0;cfg_we=0;cfg_commit=0;
        repeat(4)@(posedge clk);@(negedge clk);rst_n=1;
        if(active_ready || out_valid || !frame_ready)$fatal(1,"fast mapper reset failed");
    endtask
    task load(input integer which);
        integer i;
        @(negedge clk);cfg_begin=1;@(negedge clk);cfg_begin=0;
        for(i=0;i<N;i=i+1)begin
            if(!cfg_ready)$fatal(1,"fast LUT loading blocked");
            cfg_we=1;cfg_addr=i;cfg_data=which ? lut1[i] : lut0[i];@(negedge clk);
        end
        cfg_we=0;cfg_commit=1;@(negedge clk);cfg_commit=0;
        if(!pending || cfg_error)$fatal(1,"fast LUT commit failed");
    endtask
    task activate;
        if(!frame_ready)$fatal(1,"fast pipeline not drained at boundary");
        @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
        if(!active_ready || pending)$fatal(1,"fast map activation failed");
    endtask
    task batch(input integer which,input integer throttled);
        integer sent,received,cycles;
        reg [95:0] vector,expected;
        reg held;reg signed [31:0] held_x,held_y;
        sent=0;received=0;cycles=0;held=0;
        while(received<C)begin
            @(negedge clk);rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            in_valid=sent<C && (!throttled || rng[1]);out_ready=!throttled || rng[0];
            if(sent<C)begin vector=which ? map1[sent] : map0[sent];x=vector[95:80];y=vector[79:64];end
            @(posedge clk);
            if(held && (!out_valid || sx!==held_x || sy!==held_y))$fatal(1,"fast mapper lost stalled result");
            held=out_valid && !out_ready;held_x=sx;held_y=sy;
            if(in_valid && in_ready)sent=sent+1;
            if(out_valid && out_ready)begin
                expected=which ? map1[received] : map0[received];
                if(sx!==expected[63:32] || sy!==expected[31:0])$fatal(1,"fast mapper mismatch index=%0d",received);
                received=received+1;
            end
            cycles=cycles+1;if(cycles>10000)$fatal(1,"fast batch timeout");
        end
        @(negedge clk);in_valid=0;out_ready=0;
        if(!frame_ready)$fatal(1,"fast flight accounting mismatch");
        if(!throttled && cycles!=C+5)$fatal(1,"fast mapper not one token per clock after five stages: %0d",cycles);
        $display("PASS fast mapper: bank=%0d throttled=%0d tokens=%0d cycles=%0d",which,throttled,received,cycles);
    endtask
    initial begin
        $readmemh("vectors/mapper0.memh",map0);$readmemh("vectors/mapper1.memh",map1);
        $readmemh("vectors/map0.memh",lut0);$readmemh("vectors/map1.memh",lut1);
        reset_dut();load(0);activate();batch(0,0);batch(0,1);
        @(negedge clk);x=map0[3][95:80];y=map0[3][79:64];in_valid=1;out_ready=0;
        @(posedge clk);if(!in_ready)$fatal(1,"fast request blocked");@(negedge clk);in_valid=0;
        load(1);
        @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;
        if(!bank || !pending || frame_ready || !out_valid || sx!==map0[3][63:32] || sy!==map0[3][31:0])
            $fatal(1,"fast bank switched while old token stalled");
        out_ready=1;@(negedge clk);out_ready=0;
        activate();batch(1,0);batch(1,1);
        @(negedge clk);x=0;y=0;in_valid=1;out_ready=0;
        repeat(2)@(negedge clk);
        reset_dut();load(0);activate();batch(0,1);
        $display("FAST_MAPPER_PASSED weight_frac=%0d",`TEST_WEIGHT_FRAC);$finish;
    end
    initial begin #1000000;$fatal(1,"fast mapper global timeout");end
endmodule
