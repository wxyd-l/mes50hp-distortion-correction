`timescale 1ns/1ps
`include "rtl_parameters.vh"
module tb_package;
    localparam SW=`REMAP_SRC_WIDTH,SH=`REMAP_SRC_HEIGHT,W=`REMAP_OUT_WIDTH,H=`REMAP_OUT_HEIGHT;
    localparam STEP=1<<`REMAP_GRID_LOG2;
    localparam N=(((W-1+STEP-1)/STEP)+1)*(((H-1+STEP-1)/STEP)+1);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0,wr_ready=0,cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [15:0] cfg_addr=0;reg [63:0] cfg_data=0;
    wire start_ready,busy,done,error,cfg_ready,cfg_error,pending,active_ready,bank;
    wire req_valid,req_ready,rsp_valid,rsp_ready,wr_valid;
    wire [23:0] req_addr,wr_addr;wire [15:0] rsp_data,wr_data;
    wire [31:0] invalid_pixels;
    reg [63:0] nodes[0:N-1];
    reg [15:0] expected[0:W*H-1];reg mask[0:W*H-1];
    remap_frame_writer #(.SRC_WIDTH(SW),.SRC_HEIGHT(SH),.OUT_WIDTH(W),.OUT_HEIGHT(H),
        .GRID_LOG2(`REMAP_GRID_LOG2),.COORD_FRAC(`REMAP_COORD_FRAC),.WEIGHT_FRAC(`REMAP_WEIGHT_FRAC),.USE_FAST_MAP(`REMAP_USE_FAST_MAP)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.start_ready(start_ready),.busy(busy),.done(done),
        .invalid_pixels(invalid_pixels),.protocol_error(error),
        .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_addr(req_addr),
        .mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),.mem_rsp_data(rsp_data),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.pending(pending),.active_ready(active_ready),.active_bank(bank));
    tb_memory #(.WIDTH(SW),.HEIGHT(SH),.SOURCE_FILE("source_rgb565.memh"),.SEED(32'h2718281)) memory_model(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data));
    reg [31:0] rng=32'h1934827;
    integer i,count,cycles,invalid_count;
    reg previously_stalled;
    reg [15:0] held_data;reg [23:0] held_addr;
    initial begin
        $readmemh("grid.memh",nodes);$readmemh("expected_rgb565.memh",expected);$readmemh("expected_valid.memh",mask);
        repeat(4)@(posedge clk);
        @(negedge clk);rst_n=1;cfg_begin=1;
        @(negedge clk);cfg_begin=0;
        for(i=0;i<N;i=i+1)begin
            if(!cfg_ready)$fatal(1,"LUT loader blocked");
            cfg_we=1;cfg_addr=i;cfg_data=nodes[i];@(negedge clk);
        end
        cfg_we=0;cfg_commit=1;@(negedge clk);cfg_commit=0;
        if(!pending || cfg_error || !start_ready)$fatal(1,"LUT commit failed");
        start=1;@(negedge clk);start=0;
        count=0;cycles=0;invalid_count=0;previously_stalled=0;
        while(!done)begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};wr_ready=rng[0];
            if(previously_stalled && (!wr_valid || wr_data!==held_data || wr_addr!==held_addr))
                $fatal(1,"write token changed while stalled");
            previously_stalled=wr_valid && !wr_ready;held_data=wr_data;held_addr=wr_addr;
            if(wr_valid && wr_ready)begin
                if(count>=W*H || wr_addr!==count || wr_data!==expected[count])
                    $fatal(1,"package mismatch idx=%0d got=%h expected=%h",count,wr_data,expected[count]);
                if(!mask[count])invalid_count=invalid_count+1;
                count=count+1;
            end
            @(posedge clk);#1;cycles=cycles+1;
            if(cycles>W*H*150+10000)$fatal(1,"package rendering timeout");
            if(!done)@(negedge clk);
        end
        if(count!=W*H || invalid_pixels!==invalid_count || busy || error || cfg_error)
            $fatal(1,"package accounting/protocol failed");
        if(memory_model.read_count!==4*(count-invalid_count))$fatal(1,"package memory read accounting failed");
        $display("PACKAGE_RTL_PASSED source=%0dx%0d output=%0dx%0d pixels=%0d invalid=%0d cycles=%0d fast_map=%0d",SW,SH,W,H,count,invalid_count,cycles,`REMAP_USE_FAST_MAP);
        $finish;
    end
endmodule
