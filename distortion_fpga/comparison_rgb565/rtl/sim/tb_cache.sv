`timescale 1ns/1ps
`include "cache_vectors.vh"
module tb_cache;
    localparam LP=1<<`CACHE_LINE_LOG2;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,req_valid=0,rsp_ready=0,invalidate_valid=0;
    reg [23:0] req_addr=0;
    wire req_ready,rsp_valid,invalidate_ready,busy,error,lreq_valid,lreq_ready,lrsp_valid,lrsp_ready,lrsp_last;
    wire [15:0] rsp_data,lrsp_data;wire [23:0] lbase;
    wire [31:0] requests,hits,misses,beats;
    reg [15:0] generation=0;reg [1:0] fault_mode=0;
    reg inject_unsolicited=0;wire backend_rsp_valid;
    assign lrsp_valid=backend_rsp_valid || inject_unsolicited;
    reg [23:0] addresses[0:`CACHE_COUNT-1];
    rgb565_read_cache #(.SET_LOG2(`CACHE_SET_LOG2),.LINE_LOG2(`CACHE_LINE_LOG2)) dut(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),
        .invalidate_valid(invalidate_valid),.invalidate_ready(invalidate_ready),.busy(busy),
        .line_req_valid(lreq_valid),.line_req_ready(lreq_ready),.line_req_base_addr(lbase),
        .line_rsp_valid(lrsp_valid),.line_rsp_ready(lrsp_ready),.line_rsp_data(lrsp_data),.line_rsp_last(lrsp_last),
        .protocol_error(error),.request_count(requests),.hit_count(hits),.miss_count(misses),.fill_beat_count(beats));
    tb_line_memory #(.PIXELS(`CACHE_PIXELS),.LINE_LOG2(`CACHE_LINE_LOG2),.GENERATED(1)) memory_model(
        .clk(clk),.rst_n(rst_n),.req_valid(lreq_valid),.req_ready(lreq_ready),.req_base(lbase),
        .rsp_valid(backend_rsp_valid),.rsp_ready(lrsp_ready),.rsp_data(lrsp_data),.rsp_last(lrsp_last),
        .generation(generation),.fault_mode(fault_mode));
    integer i,cycles=0;
    always @(posedge clk)begin cycles<=cycles+1;if(cycles>2000000)$fatal(1,"cache global timeout");end
    task reset_pair;
        begin
            @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;invalidate_valid=0;fault_mode=0;inject_unsolicited=0;
            #1;if(req_ready || rsp_valid || lreq_valid || lrsp_ready || invalidate_ready)$fatal(1,"cache handshakes active during reset");
            repeat(3)@(negedge clk);rst_n=1;@(negedge clk);
            if(rsp_valid || error || requests || hits || misses || beats)$fatal(1,"cache reset failed");
        end
    endtask
    task send_request(input integer address);
        begin
            @(negedge clk);req_addr=address;req_valid=1;
            while(!req_ready)@(negedge clk);
            @(posedge clk);@(negedge clk);req_valid=0;
        end
    endtask
    task read_pixel(input integer address,input integer stall);
        reg [15:0] value;
        integer j;
        begin
            send_request(address);
            while(!rsp_valid)begin @(negedge clk);if(error)$fatal(1,"unexpected cache error");end
            value=((address*37)^16'h5a69^generation);
            if(rsp_data!==value)$fatal(1,"cache pixel mismatch addr=%0d got=%h expected=%h",address,rsp_data,value);
            for(j=0;j<stall;j=j+1)begin
                @(negedge clk);
                if(!rsp_valid || rsp_data!==value || req_ready || invalidate_ready)$fatal(1,"held response changed/accepted invalidate");
            end
            rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;
        end
    endtask
    task flush;
        begin
            @(negedge clk);invalidate_valid=1;#1;
            while(!invalidate_ready)@(negedge clk);
            if(req_ready)$fatal(1,"invalidate must take priority over new request");
            @(posedge clk);@(negedge clk);invalidate_valid=0;
            if(requests || hits || misses || beats)$fatal(1,"frame statistics not cleared");
        end
    endtask
    initial begin
        $readmemh("addresses.memh",addresses);
        reset_pair();
        for(i=0;i<`CACHE_COUNT;i=i+1)read_pixel(addresses[i],i%5);
        if(requests!=`CACHE_COUNT || hits!=`CACHE_HITS || misses!=`CACHE_MISSES ||
           beats!=`CACHE_MISSES*LP || memory_model.line_count!=misses || memory_model.beat_count!=beats)
            $fatal(1,"cache oracle accounting mismatch requests=%0d hits=%0d misses=%0d beats=%0d",requests,hits,misses,beats);
        $display("CACHE_TRACE_PASSED line_log2=%0d set_log2=%0d requests=%0d hits=%0d misses=%0d",`CACHE_LINE_LOG2,`CACHE_SET_LOG2,requests,hits,misses);
        // Same logical address, NEW immutable source frame: must invalidate.
        flush();generation=16'h9123;read_pixel(0,9);read_pixel(0,0);
        if(misses!=1 || hits!=1)$fatal(1,"cache invalidate/refill not effective");
        // Invalidate cannot abort a frontend-held response. It waits for idle.
        send_request(0);while(!rsp_valid)@(negedge clk);
        invalidate_valid=1;repeat(5)begin @(negedge clk);if(invalidate_ready)$fatal(1,"invalidate raced response");end
        rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;
        if(!invalidate_ready || req_ready)$fatal(1,"queued invalidate priority failed");
        @(posedge clk);@(negedge clk);invalidate_valid=0;
        // Joint reset while a fill is partly received; partial line never reused.
        send_request(123);while(beats<2)@(negedge clk);
        reset_pair();generation=16'h4231;read_pixel(123,0);
        if(misses!=1 || hits!=0)$fatal(1,"partial fill survived reset");
        reset_pair();read_pixel(0,0);send_request(0);while(!rsp_valid)@(negedge clk);
        reset_pair();generation=16'h1111;read_pixel(0,0);
        // Early last and missing last fail closed without a fabricated pixel.
        for(i=1;i<=2;i=i+1)begin
            reset_pair();fault_mode=i;send_request(42);
            while(!error)@(negedge clk);
            repeat(5)begin @(negedge clk);if(rsp_valid || req_ready || invalidate_ready || lrsp_ready)$fatal(1,"cache protocol error did not fail closed");end
        end
        reset_pair();inject_unsolicited=1;
        @(posedge clk);@(negedge clk);inject_unsolicited=0;
        if(!error || req_ready || rsp_valid || invalidate_ready)$fatal(1,"unsolicited response was not rejected");
        reset_pair();read_pixel(42,3);
        $display("CACHE_RTL_PASSED line_log2=%0d set_log2=%0d reset/invalidate/backpressure/last-error",`CACHE_LINE_LOG2,`CACHE_SET_LOG2);
        $finish;
    end
endmodule
