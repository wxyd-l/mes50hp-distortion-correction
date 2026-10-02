`timescale 1ns/1ps
`ifdef DDR_CACHE
module tb_frame_cached;
`else
module tb_frame;
`endif
    localparam W=64,H=48,N=W*H,CASES=5;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,start=0;
    reg [31:0] cfg[0:13];
    reg [31:0] parameters_mem[0:CASES*14-1];
    reg [23:0] source[0:N-1];
    reg [23:0] expected[0:CASES*N-1];
    wire busy,done,frame_overflow,out_valid,out_last;
    wire [31:0] frame_cycles,pixels_emitted;
    wire req_valid,rsp_ready;
    reg req_ready=0,rsp_valid=0,out_ready=0;
    wire [31:0] req_addr;
    reg [31:0] rsp_data=0;
    wire [23:0] out_rgb;
    wire [15:0] out_u,out_v;
    reg [31:0] rng=32'h12facade;
    integer test_case=0,received=0,requests=0,total_cycles=0;
    integer delay_left=0,pending_address=0,pending=0,i;
    reg stalled_out=0,stalled_req=0;
    reg [56:0] held_output;
    reg [31:0] held_address;
`ifdef DDR_CACHE
    wire start_ready,memory_error;
    wire [31:0] cache_hits,cache_misses;
    wire [27:0] araddr;
    wire [3:0] arlen,arid;
    reg [255:0] line_rsp_data=0;
    integer lane;
    assign req_addr={2'd0,araddr,2'd0};
    assign rsp_ready=1'b1; // The real Pango interface has no response ready.
    remap_ddr_read_top #(.WIDTH(W),.HEIGHT(H),.CACHE_LINES(64)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.start_ready(start_ready),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .k1(cfg[6]),.k2(cfg[7]),.p1(cfg[8]),.p2(cfg[9]),.fx(cfg[10]),.fy(cfg[11]),.cx(cfg[12]),.cy(cfg[13]),
        .busy(busy),.done(done),.frame_overflow(frame_overflow),.memory_error(memory_error),
        .frame_cycles(frame_cycles),.pixels_emitted(pixels_emitted),.cache_hits(cache_hits),.cache_misses(cache_misses),
        .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_u(out_u),.out_v(out_v),.out_last(out_last),
        .axi_araddr(araddr),.axi_arlen(arlen),.axi_arid(arid),.axi_arvalid(req_valid),.axi_arready(req_ready),
        .axi_rdata(line_rsp_data),.axi_rid(4'd0),.axi_rvalid(rsp_valid),.axi_rlast(1'b1));
`else
    remap_frame_core #(.WIDTH(W),.HEIGHT(H)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .k1(cfg[6]),.k2(cfg[7]),.p1(cfg[8]),.p2(cfg[9]),.fx(cfg[10]),.fy(cfg[11]),.cx(cfg[12]),.cy(cfg[13]),
        .busy(busy),.done(done),.frame_overflow(frame_overflow),.frame_cycles(frame_cycles),.pixels_emitted(pixels_emitted),
        .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_addr(req_addr),
        .mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),.mem_rsp_data(rsp_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_u(out_u),.out_v(out_v),.out_last(out_last));
`endif

    // Response source holds valid/data until accepted, with random request/return delays.
    always @(posedge clk) begin
        if (!rst_n) begin
            pending<=0; rsp_valid<=0; rsp_data<=0; delay_left<=0;
            stalled_out<=0; stalled_req<=0;
        end else begin
            if (stalled_out && (!out_valid || {out_last,out_u,out_v,out_rgb} !== held_output))
                $fatal(1,"Output changed under backpressure");
            if (stalled_req && (!req_valid || req_addr !== held_address))
                $fatal(1,"Read request changed before acceptance");
            stalled_out<=out_valid&&!out_ready;
            held_output<={out_last,out_u,out_v,out_rgb};
            stalled_req<=req_valid&&!req_ready; held_address<=req_addr;
            if (req_valid && req_ready) begin
                if (pending || rsp_valid || req_addr[1:0]!=0 || req_addr>=N*4)
                    $fatal(1,"Invalid memory request %h",req_addr);
`ifdef DDR_CACHE
                if(arlen!=0 || arid!=0 || req_addr[4:0]!=0) $fatal(1,"Invalid Pango line command");
`endif
                pending<=1; pending_address<=req_addr>>2;
                delay_left<=rng[11:8]; requests=requests+1;
            end
            if (pending && !rsp_valid) begin
                if (delay_left==0) begin
                    rsp_data<={8'd0,source[pending_address]}; rsp_valid<=1; pending<=0;
`ifdef DDR_CACHE
                    for(lane=0;lane<8;lane=lane+1)
                        line_rsp_data[lane*32+:32]<={8'd0,source[pending_address+lane]};
`endif
                end else delay_left<=delay_left-1;
            end
            if (rsp_valid && rsp_ready) rsp_valid<=0;
            if (out_valid && out_ready) begin
                if (received>=N || out_u !== received%W || out_v !== received/W)
                    $fatal(1,"Frame ordering case=%0d pixel=%0d u=%0d v=%0d",test_case,received,out_u,out_v);
                if (out_rgb !== expected[test_case*N+received])
                    $fatal(1,"Frame RGB case=%0d pixel=%0d got=%h expected=%h",test_case,received,out_rgb,expected[test_case*N+received]);
                if (out_last !== (received==N-1)) $fatal(1,"Bad last marker");
                received=received+1;
            end
        end
    end
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        req_ready=(rng[2:0]!=0);
        out_ready=(rng[6:3]>4);
    end
    initial begin
        $readmemh("build/regression/parameters.mem",parameters_mem);
        $readmemh("build/regression/input_rgb.mem",source);
        $readmemh("build/regression/expected_rgb.mem",expected);
        for(i=0;i<14;i=i+1) cfg[i]=0;
        repeat(5) @(negedge clk);
        rst_n=1;
        // Abort an in-flight read. Both endpoints reset: stale untagged replies
        // must be flushed by the adapter, as required by the interface contract.
        for(i=0;i<14;i=i+1) cfg[i]=parameters_mem[i];
        start=1; @(negedge clk); start=0;
        while (!pending) @(negedge clk);
        rst_n=0;
        repeat(3) @(negedge clk);
        if(busy || rsp_valid || pending) $fatal(1,"Reset did not flush both endpoints");
        rst_n=1;
        for (test_case=0;test_case<CASES;test_case=test_case+1) begin
            for(i=0;i<14;i=i+1) cfg[i]=parameters_mem[test_case*14+i];
            received=0; requests=0; total_cycles=0;
            start=1; @(negedge clk); start=0;
            while (!done) begin
                @(negedge clk);
                total_cycles=total_cycles+1;
                // External writes and spurious start while busy must not change this frame.
                if(total_cycles==30) begin
                    for(i=0;i<14;i=i+1) cfg[i]=32'h5a5a5a5a;
                    start=1;
                end
                if(total_cycles==31) start=0;
                if(total_cycles>500000) $fatal(1,"Frame timeout");
            end
            if(received!=N || pixels_emitted!=N || busy || pending || rsp_valid)
                $fatal(1,"Frame completion state invalid");
            if(frame_overflow !== (test_case==4)) $fatal(1,"Overflow status mismatch");
            if(test_case==4 && requests!=0) $fatal(1,"Overflow accessed source memory");
`ifdef DDR_CACHE
            if(memory_error) $fatal(1,"Unexpected memory protocol error");
            if(test_case==0 && requests!=N/8) $fatal(1,"Identity cache did not fetch exactly one line per eight pixels");
            $display("Cache counters hits=%0d misses=%0d",cache_hits,cache_misses);
`endif
            $display("PASS frame case=%0d pixels=%0d reads=%0d cycles=%0d overflow=%0b",test_case,received,requests,frame_cycles,frame_overflow);
            repeat(3) @(negedge clk);
        end
`ifdef DDR_CACHE
        $display("PASS tb_frame_cached: %0d RGB outputs through cache and Pango read bridge",CASES*N);
`else
        $display("PASS tb_frame: %0d RGB outputs; randomized memory and sink; frame-atomic configuration",CASES*N);
`endif
        $finish;
    end
endmodule
