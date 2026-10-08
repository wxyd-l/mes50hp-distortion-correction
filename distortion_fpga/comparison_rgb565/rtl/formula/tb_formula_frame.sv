`timescale 1ns/1ps
`include "formula_parameters.vh"
// Shared cache and line-memory model, independent formula coordinates/pixels.
module tb_formula_frame;
    localparam SW=`FORMULA_SW,SH=`FORMULA_SH,W=`FORMULA_W,H=`FORMULA_H;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0,wr_ready=0;
    reg [447:0] parameters;reg [447:0] configuration[0:0];
    wire start_ready,busy,done,error,req_valid,req_ready,rsp_valid,rsp_ready,wr_valid;
    wire [23:0] req_addr,wr_addr,lbase;
    wire [15:0] rsp_data,wr_data,lrsp_data;
    wire [31:0] invalid_pixels,overflow_pixels,requests,hits,misses,beats;
    wire lreq_valid,lreq_ready,lrsp_valid,lrsp_ready,lrsp_last,cache_error,cache_busy,invalidate_ready;
    reg [15:0] expected[0:W*H-1];reg mask[0:W*H-1];
    reg [31:0] expected_x[0:W*H-1],expected_y[0:W*H-1];
    brown_frame_writer #(.SRC_WIDTH(SW),.SRC_HEIGHT(SH),.OUT_WIDTH(W),.OUT_HEIGHT(H)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.parameters(parameters),.start_ready(start_ready),.busy(busy),.done(done),
        .invalid_pixels(invalid_pixels),.overflow_pixels(overflow_pixels),.protocol_error(error),
        .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_addr(req_addr),
        .mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),.mem_rsp_data(rsp_data),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data));
    rgb565_read_cache #(.LINE_LOG2(4),.SET_LOG2(9)) cache(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),
        .invalidate_valid(1'b0),.invalidate_ready(invalidate_ready),.busy(cache_busy),
        .line_req_valid(lreq_valid),.line_req_ready(lreq_ready),.line_req_base_addr(lbase),
        .line_rsp_valid(lrsp_valid),.line_rsp_ready(lrsp_ready),.line_rsp_data(lrsp_data),.line_rsp_last(lrsp_last),
        .protocol_error(cache_error),.request_count(requests),.hit_count(hits),.miss_count(misses),.fill_beat_count(beats));
    tb_line_memory #(.PIXELS(SW*SH),.LINE_LOG2(4),.SOURCE_FILE("source_rgb565.memh")) memory_model(
        .clk(clk),.rst_n(rst_n),.req_valid(lreq_valid),.req_ready(lreq_ready),.req_base(lbase),
        .rsp_valid(lrsp_valid),.rsp_ready(lrsp_ready),.rsp_data(lrsp_data),.rsp_last(lrsp_last),
        .generation(16'h0),.fault_mode(2'b0));
    reg [31:0] rng=32'h1934827;
    integer count,cycles,invalid_count,coordinate_count;
    reg held;reg [15:0] held_data;reg [23:0] held_addr;
    // Every completed coordinate is checked before sampling, not just RGB.
    always @(posedge clk)begin
        if(rst_n && dut.mapped)begin
            if(coordinate_count>=W*H || dut.mapping_overflow!==(`FORMULA_OVERFLOW!=0) ||
               dut.sx!==expected_x[coordinate_count] || dut.sy!==expected_y[coordinate_count])
                $fatal(1,"formula coordinate mismatch %0d got=%h,%h",coordinate_count,dut.sx,dut.sy);
            coordinate_count=coordinate_count+1;
        end
    end
    task run_frame;
        begin
            @(negedge clk);parameters=configuration[0];start=1;
            @(negedge clk);start=0;parameters=~configuration[0]; // external updates must not corrupt frame
            count=0;cycles=0;invalid_count=0;coordinate_count=0;held=0;
            while(!done)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};wr_ready=rng[0];
                if(held && (!wr_valid || wr_data!==held_data || wr_addr!==held_addr))$fatal(1,"formula write changed under stall");
                held=wr_valid && !wr_ready;held_data=wr_data;held_addr=wr_addr;
                if(wr_valid && wr_ready)begin
                    if(count>=W*H || wr_addr!==count || wr_data!==expected[count])
                        $fatal(1,"formula pixel mismatch %0d got=%h expected=%h",count,wr_data,expected[count]);
                    if(!mask[count])invalid_count=invalid_count+1;
                    count=count+1;
                end
                @(posedge clk);#1;cycles=cycles+1;
                if(cycles>W*H*500+10000)$fatal(1,"formula timeout");
                if(cache_error)$fatal(1,"formula cache error");
                if(!done)@(negedge clk);
            end
            if(count!=W*H || coordinate_count!=W*H || invalid_pixels!==invalid_count ||
               overflow_pixels!==`FORMULA_OVERFLOW || busy || error || cache_busy ||
               requests!==4*(count-invalid_count) || hits!==`FORMULA_HITS || misses!==`FORMULA_MISSES ||
               beats!==16*misses || memory_model.line_count!==misses || memory_model.beat_count!==beats)
                $fatal(1,"formula frame accounting failed pixels=%0d coords=%0d invalid=%0d overflow=%0d hits=%0d misses=%0d",count,coordinate_count,invalid_pixels,overflow_pixels,hits,misses);
        end
    endtask
    initial begin
        $readmemh("parameters.memh",configuration);$readmemh("expected_rgb565.memh",expected);
        $readmemh("expected_valid.memh",mask);$readmemh("expected_x.memh",expected_x);$readmemh("expected_y.memh",expected_y);
        parameters=0;coordinate_count=0;
        repeat(4)@(posedge clk);
        @(negedge clk);rst_n=1;
        // Small fixtures additionally abort during a held write and restart with
        // jointly-reset backend/cache, exercising reset masking and recovery.
        if(W*H<10000)begin
            parameters=configuration[0];start=1;@(negedge clk);start=0;
            wait(wr_valid);@(negedge clk);rst_n=0;#1;
            if(wr_valid || req_valid || rsp_ready || start_ready)$fatal(1,"formula reset handshake masking");
            repeat(3)@(negedge clk);rst_n=1;coordinate_count=0;
        end
        run_frame();
        $display("FORMULA_FRAME_PASSED pixels=%0d invalid=%0d overflow=%0d cycles=%0d hits=%0d misses=%0d",count,invalid_pixels,overflow_pixels,cycles,hits,misses);
        $finish;
    end
endmodule
