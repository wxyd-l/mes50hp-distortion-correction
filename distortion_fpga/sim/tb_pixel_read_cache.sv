`timescale 1ns/1ps
module tb_pixel_read_cache;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,invalidate=0,req_valid=0,rsp_ready=0;
    reg [31:0] req_addr=0;
    wire invalidate_ready,req_ready,rsp_valid;
    wire [31:0] rsp_data,hit_count,miss_count;
    wire [2:0] rsp_error;
    wire line_req_valid,line_rsp_ready;
    reg line_req_ready=0,line_rsp_valid=0;
    wire [31:0] line_req_addr;
    reg [255:0] line_rsp_data=0;
    reg [2:0] line_rsp_error=0;
    pixel_read_cache #(.LINES(4)) dut(.*);
    integer reads=0,checks=0,seed=32'h1badf00d,delay_left=0;
    integer epoch=0,errors_remaining=0;
    reg pending=0;
    reg [31:0] backend_address=0;
    reg [2:0] backend_error=0;
    reg [31:0] random_state=32'hb16b00b5;
    function automatic [31:0] pixel(input [31:0] address,input integer frame);
        pixel = ((address >> 2)*32'h00012345 ^ (frame*32'h000abcde)) & 32'h00ffffff;
    endfunction

    // Backend accepts requests under deterministic pseudo-random backpressure.
    // Response valid/data remain stable until accepted.
    always @(negedge clk) begin
        if (!rst_n) begin
            line_req_ready=0;
            rsp_ready=0;
        end else begin
            random_state = {random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            line_req_ready=!pending && !line_rsp_valid && random_state[0];
            rsp_ready=random_state[3] || random_state[8];
        end
    end
    integer lane;
    always @(posedge clk) begin
        if (!rst_n) begin
            line_rsp_valid<=0;
            pending<=0;
            reads<=0;
        end else begin
            if (line_req_valid && line_req_ready) begin
                if (line_req_addr[4:0] != 0) $fatal(1,"unaligned backend request");
                if (pending || line_rsp_valid) $fatal(1,"multiple outstanding transactions");
                reads<=reads+1;
                backend_address<=line_req_addr;
                backend_error<=errors_remaining > 0 ? 3'b100 : 0;
                if (errors_remaining > 0) errors_remaining<=errors_remaining-1;
                delay_left<=2+(random_state[6:4]);
                pending<=1;
            end
            if (pending) begin
                if (delay_left > 0) delay_left<=delay_left-1;
                else begin
                    pending<=0;
                    line_rsp_valid<=1;
                    line_rsp_error<=backend_error;
                    for (lane=0;lane<8;lane=lane+1)
                        line_rsp_data[lane*32 +: 32]<=pixel(backend_address+4*lane,epoch);
                end
            end
            if (line_rsp_valid && line_rsp_ready) line_rsp_valid<=0;
        end
    end

    // Check ready/valid stability independently from transaction task checks.
    reg was_stalled=0,was_line_stalled=0;
    reg [34:0] stalled_response;
    reg [31:0] stalled_address;
    always @(posedge clk) if (rst_n) begin
        if (was_stalled && (!rsp_valid || {rsp_error,rsp_data} !== stalled_response))
            $fatal(1,"pixel response changed under backpressure");
        if (was_line_stalled && (!line_req_valid || line_req_addr !== stalled_address))
            $fatal(1,"backend request changed under backpressure");
        was_stalled<=rsp_valid&&!rsp_ready;
        stalled_response<={rsp_error,rsp_data};
        was_line_stalled<=line_req_valid&&!line_req_ready;
        stalled_address<=line_req_addr;
    end

    task automatic access(input [31:0] address,input [2:0] expected_error);
        reg [31:0] expected;
        begin
            repeat (random_state[10:9]) @(negedge clk);
            @(negedge clk);
            req_addr=address;
            req_valid=1;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk); req_valid=0;
            @(posedge clk);
            while (!rsp_valid) @(posedge clk);
            expected = expected_error == 0 ? pixel(address,epoch) : 0;
            if (rsp_error !== expected_error || rsp_data !== expected)
                $fatal(1,"addr=%h expected=%h/%h received=%h/%h",address,expected,expected_error,rsp_data,rsp_error);
            while (!rsp_ready) @(posedge clk);
            checks=checks+1;
            @(negedge clk);
        end
    endtask
    task automatic clear_cache;
        begin
            @(negedge clk); invalidate=1;
            @(posedge clk);
            while (!invalidate_ready) @(posedge clk);
            if (req_ready) $fatal(1,"invalidate did not suppress request ready");
            @(negedge clk); invalidate=0;
        end
    endtask

    integer i,baseline;
    initial begin
        repeat (4) @(negedge clk);
        rst_n=1;
        // All eight 32-bit words share one 32-byte fetch.
        for (i=0;i<8;i=i+1) access(32'h100+i*4,0);
        if (reads != 1 || miss_count != 1 || hit_count != 7) $fatal(1,"same-line reuse failed");
        // 4 lines * 32 bytes apart collide, and re-access must refetch.
        access(32'h180,0);
        access(32'h100,0);
        if (reads != 3) $fatal(1,"conflict replacement failed");
        clear_cache();
        epoch=1;
        access(32'h104,0);
        if (reads != 4) $fatal(1,"new source frame was not invalidated");
        // Address errors must never reach the line backend.
        baseline=reads;
        access(32'h101,3'b001);
        access(32'h40000000,3'b010);
        if (reads != baseline) $fatal(1,"bad address reached backend");
        // A failed conflicting fill may not replace the old good line.
        errors_remaining=1;
        access(32'h184,3'b100);
        baseline=reads;
        access(32'h104,0);
        if (reads != baseline) $fatal(1,"line error destroyed good cache entry");
        access(32'h184,0);
        if (reads != baseline+1) $fatal(1,"failed line poisoned cache");
        // Invalidate waits for the outstanding response and takes precedence
        // over a simultaneous pixel request once IDLE is reached.
        fork
            begin access(32'h340,0); end
            begin
                wait(line_req_valid);
                @(negedge clk);
                invalidate=1;
                req_valid=1;
                req_addr=32'h700;
                if (invalidate_ready) $fatal(1,"busy invalidate accepted too early");
                @(posedge clk);
                while (!invalidate_ready) begin
                    if (req_ready) $fatal(1,"request accepted during pending invalidate");
                    @(posedge clk);
                end
                if (req_ready) $fatal(1,"invalidate lost priority to simultaneous request");
                @(negedge clk);
                invalidate=0;
                req_valid=0;
            end
        join
        baseline=reads;
        epoch=epoch+1;
        access(32'h340,0);
        if (reads != baseline+1) $fatal(1,"busy invalidate did not clear returned line");
        // Varied locality under randomized request/response stalls.
        for (i=0;i<180;i=i+1) begin
            access(32'h200+((i*13)%64)*4,0);
            if (i%23==0) begin clear_cache(); epoch=epoch+1; end
        end
        if (hit_count+miss_count != checks-2) $fatal(1,"hit/miss counters omit transactions");
        $display("PASS pixel_read_cache checks=%0d backend_reads=%0d hits=%0d misses=%0d",checks,reads,hit_count,miss_count);
        $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule
