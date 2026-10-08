`timescale 1ns/1ps
`include "rtl_parameters.vh"
// Full package checked through the cache and an ordered, stalled line backend.
module tb_package_cache;
    localparam SW=`REMAP_SRC_WIDTH,SH=`REMAP_SRC_HEIGHT,W=`REMAP_OUT_WIDTH,H=`REMAP_OUT_HEIGHT;
    localparam STEP=1<<`REMAP_GRID_LOG2;
    localparam N=(((W-1+STEP-1)/STEP)+1)*(((H-1+STEP-1)/STEP)+1);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0,wr_ready=0,cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [15:0] cfg_addr=0;reg [63:0] cfg_data=0;
    wire start_ready,busy,done,error,cfg_ready,cfg_error,pending,active_ready,bank;
    wire req_valid,req_ready,rsp_valid,rsp_ready,wr_valid;
    wire [23:0] req_addr,wr_addr;wire [15:0] rsp_data,wr_data;
    wire [31:0] invalid_pixels,requests,hits,misses,beats;
    wire lreq_valid,lreq_ready,lrsp_valid,lrsp_ready,lrsp_last,cache_error,cache_busy,invalidate_ready;
    wire [23:0] lbase;wire [15:0] lrsp_data;
    reg [63:0] nodes[0:N-1];reg [15:0] expected[0:W*H-1];reg mask[0:W*H-1];
    remap_frame_writer #(.SRC_WIDTH(SW),.SRC_HEIGHT(SH),.OUT_WIDTH(W),.OUT_HEIGHT(H),
        .GRID_LOG2(`REMAP_GRID_LOG2),.COORD_FRAC(`REMAP_COORD_FRAC),.WEIGHT_FRAC(`REMAP_WEIGHT_FRAC),.USE_FAST_MAP(`REMAP_USE_FAST_MAP)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.start_ready(start_ready),.busy(busy),.done(done),
        .invalid_pixels(invalid_pixels),.protocol_error(error),
        .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_addr(req_addr),
        .mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),.mem_rsp_data(rsp_data),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(cfg_ready),.cfg_error(cfg_error),.pending(pending),.active_ready(active_ready),.active_bank(bank));
    rgb565_read_cache #(.LINE_LOG2(`REMAP_CACHE_LINE_LOG2),.SET_LOG2(`REMAP_CACHE_SET_LOG2)) cache(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),
        .invalidate_valid(1'b0),.invalidate_ready(invalidate_ready),.busy(cache_busy),
        .line_req_valid(lreq_valid),.line_req_ready(lreq_ready),.line_req_base_addr(lbase),
        .line_rsp_valid(lrsp_valid),.line_rsp_ready(lrsp_ready),.line_rsp_data(lrsp_data),.line_rsp_last(lrsp_last),
        .protocol_error(cache_error),.request_count(requests),.hit_count(hits),.miss_count(misses),.fill_beat_count(beats));
    tb_line_memory #(.PIXELS(SW*SH),.LINE_LOG2(`REMAP_CACHE_LINE_LOG2),.SOURCE_FILE("source_rgb565.memh")) memory_model(
        .clk(clk),.rst_n(rst_n),.req_valid(lreq_valid),.req_ready(lreq_ready),.req_base(lbase),
        .rsp_valid(lrsp_valid),.rsp_ready(lrsp_ready),.rsp_data(lrsp_data),.rsp_last(lrsp_last),
        .generation(16'h0),.fault_mode(2'b0));
    reg [31:0] rng=32'h1934827;
    integer i,count,cycles,invalid_count;
    reg previously_stalled;reg [15:0] held_data;reg [23:0] held_addr;
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
                $fatal(1,"cached write token changed while stalled");
            previously_stalled=wr_valid && !wr_ready;held_data=wr_data;held_addr=wr_addr;
            if(wr_valid && wr_ready)begin
                if(count>=W*H || wr_addr!==count || wr_data!==expected[count])
                    $fatal(1,"cached package mismatch idx=%0d got=%h expected=%h",count,wr_data,expected[count]);
                if(!mask[count])invalid_count=invalid_count+1;
                count=count+1;
            end
            @(posedge clk);#1;cycles=cycles+1;
            if(cycles>W*H*500+10000)$fatal(1,"cached package timeout");
            if(cache_error)$fatal(1,"cache backend protocol failed");
            if(!done)@(negedge clk);
        end
        if(count!=W*H || invalid_pixels!==invalid_count || busy || error || cfg_error || cache_busy)
            $fatal(1,"cached package accounting/protocol failed");
        if(requests!==4*(count-invalid_count) || hits!==`REMAP_CACHE_EXPECTED_HITS ||
           misses!==`REMAP_CACHE_EXPECTED_MISSES || beats!==misses*(1<<`REMAP_CACHE_LINE_LOG2) ||
           memory_model.line_count!==misses || memory_model.beat_count!==beats)
            $fatal(1,"cached package miss/hit/fill accounting failed requests=%0d hits=%0d misses=%0d beats=%0d",requests,hits,misses,beats);
        $display("PACKAGE_RTL_PASSED source=%0dx%0d output=%0dx%0d pixels=%0d invalid=%0d cycles=%0d fast_map=%0d cache=1 hits=%0d misses=%0d fill_beats=%0d",SW,SH,W,H,count,invalid_count,cycles,`REMAP_USE_FAST_MAP,hits,misses,beats);
        $finish;
    end
endmodule
