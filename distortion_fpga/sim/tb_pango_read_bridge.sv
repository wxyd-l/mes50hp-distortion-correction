`timescale 1ns/1ps
module tb_pango_read_bridge;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, req_valid=0, rsp_ready=0, axi_arready=0;
    reg [31:0] req_addr=0;
    reg [255:0] axi_rdata=0;
    reg [3:0] axi_rid=0;
    reg axi_rvalid=0, axi_rlast=0;
    wire req_ready, rsp_valid, axi_arvalid, protocol_error;
    wire [255:0] rsp_data;
    wire [2:0] rsp_error;
    wire [27:0] axi_araddr;
    wire [3:0] axi_arlen, axi_arid;
    pango_read_bridge dut(.*);
    integer requests=0, returns=0, ars=0, outstanding=0, checks=0;
    reg ar_stalled=0, rsp_stalled=0;
    reg [27:0] held_addr;
    reg [255:0] held_data;
    reg [2:0] held_error;
    integer seed=32'h25450102, random_discard;
    integer n, ad, rd, stall, mode;
    reg [31:0] addr;

    // Independent protocol scoreboard, including payload stability across stalls.
    always @(posedge clk) begin
        if (!rst_n) begin
            requests=0; returns=0; ars=0; outstanding=0;
            ar_stalled=0; rsp_stalled=0;
        end else begin
            if (ar_stalled && (!axi_arvalid || axi_araddr !== held_addr || axi_arlen !== 0 || axi_arid !== 0))
                $fatal(1,"AR changed while waiting for ready");
            if (rsp_stalled && (!rsp_valid || rsp_data !== held_data || rsp_error !== held_error))
                $fatal(1,"response changed under backpressure");
            ar_stalled=axi_arvalid && !axi_arready;
            rsp_stalled=rsp_valid && !rsp_ready;
            held_addr=axi_araddr; held_data=rsp_data; held_error=rsp_error;
            if (req_valid && req_ready) begin
                if (outstanding != 0) $fatal(1,"multiple outstanding requests");
                requests=requests+1; outstanding=outstanding+1;
            end
            if (axi_arvalid && axi_arready) ars=ars+1;
            if (rsp_valid && rsp_ready) begin
                if (outstanding != 1) $fatal(1,"response without request");
                returns=returns+1; outstanding=outstanding-1;
            end
        end
    end

    function [255:0] pattern(input [31:0] a);
        integer i;
        begin
            for (i=0;i<8;i=i+1) pattern[32*i+:32]=a ^ (32'h91a527c3 + i*32'h01100111);
        end
    endfunction

    // The model is flushed together with the bridge: no old response is retained.
    task reset_drained;
        begin
            @(negedge clk);
            rst_n=0; req_valid=0; rsp_ready=0; axi_arready=0; axi_rvalid=0;
            repeat(3) @(posedge clk);
            @(negedge clk); rst_n=1;
            @(negedge clk);
            if (!req_ready || rsp_valid || axi_arvalid || protocol_error) $fatal(1,"reset did not clear state");
        end
    endtask

    task issue_request(input [31:0] a);
        begin
            @(negedge clk); req_addr=a; req_valid=1;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk); req_valid=0;
        end
    endtask

    // error_mode: 0 normal, 1 bad RID, 2 missing RLAST, 3 both.
    task transaction(input [31:0] a, input integer ar_delay, input integer return_delay,
                     input integer response_stall, input integer error_mode, input integer inject_extra);
        integer old_ar, i;
        reg [2:0] expected_error;
        reg [255:0] expected_data;
        reg invalid_address;
        begin
            old_ar=ars;
            invalid_address=(|a[4:0]) || (|a[31:30]);
            expected_error=invalid_address ? {1'b0,(|a[31:30]),(|a[4:0])} : {(error_mode!=0),2'b00};
            expected_data=invalid_address ? 256'd0 : pattern(a);
            issue_request(a);
            if (!invalid_address) begin
                if (!axi_arvalid || axi_araddr !== a[29:2] || axi_arlen !== 0 || axi_arid !== 0)
                    $fatal(1,"bad address/length translation for %h", a);
                repeat(ar_delay) @(posedge clk);
                @(negedge clk); axi_arready=1;
                axi_rdata=expected_data;
                axi_rid=(error_mode==1 || error_mode==3) ? 4'd7 : 4'd0;
                axi_rlast=!(error_mode==2 || error_mode==3);
                // Test a return on the same cycle as AR acceptance too.
                if (return_delay==0) axi_rvalid=1;
                @(posedge clk);
                @(negedge clk); axi_arready=0; axi_rvalid=0;
                if (return_delay!=0) begin
                    repeat(return_delay) @(posedge clk);
                    @(negedge clk); axi_rvalid=1;
                    @(posedge clk);
                    @(negedge clk); axi_rvalid=0;
                end
            end
            if (!rsp_valid || rsp_data !== expected_data || rsp_error !== expected_error)
                $fatal(1,"bad response a=%h goterr=%b expected=%b", a,rsp_error,expected_error);
            if (ars != old_ar + (invalid_address ? 0:1)) $fatal(1,"wrong number of ARs");
            // A waiting next request must not overwrite the response register.
            req_addr=32'h12340; req_valid=1;
            for(i=0;i<response_stall;i=i+1) begin
                @(negedge clk);
                if (req_ready || !rsp_valid || rsp_data !== expected_data || rsp_error !== expected_error)
                    $fatal(1,"response overwrite or premature request ready");
            end
            if (inject_extra) begin
                @(negedge clk); axi_rvalid=1; axi_rdata=~expected_data; axi_rid=0; axi_rlast=1;
                @(posedge clk);
                @(negedge clk); axi_rvalid=0;
                if (!protocol_error || rsp_data !== expected_data || rsp_error !== expected_error)
                    $fatal(1,"unexpected return overwrote buffered response");
            end
            @(negedge clk); rsp_ready=1;
            @(posedge clk);
            @(negedge clk); rsp_ready=0; req_valid=0;
            if (rsp_valid || !req_ready) $fatal(1,"response not consumed exactly once");
            checks=checks+1;
        end
    endtask

    initial begin
        random_discard=$urandom(seed);
        reset_drained;
        transaction(32'd0,12,8,100,0,0);
        transaction(32'h3fffffe0,0,0,0,0,0); // last legal line
        transaction(32'h00000001,0,0,12,0,0);
        transaction(32'h40000000,0,0,3,0,0);
        transaction(32'hffffffff,0,0,2,0,0);
        if(protocol_error) $fatal(1,"address errors falsely flagged IP protocol error");
        for(n=0;n<100;n=n+1) begin
            addr=($urandom & 32'h3fffffe0);
            ad=$urandom_range(0,12); rd=$urandom_range(0,8); stall=$urandom_range(0,30);
            transaction(addr,ad,rd,stall,0,0);
        end
        if(protocol_error || requests != returns) $fatal(1,"legal random transactions failed");
        for(mode=1;mode<=3;mode=mode+1) begin
            reset_drained;
            transaction(32'h200,2,2,12,mode,0);
            if(!protocol_error) $fatal(1,"RID/RLAST error not reported");
        end
        reset_drained;
        transaction(32'h400,2,1,10,0,1);
        reset_drained;
        // Unexpected idle return is dropped and diagnosed, without a response token.
        @(negedge clk); axi_rvalid=1; axi_rlast=1; axi_rid=0;
        @(posedge clk);
        @(negedge clk); axi_rvalid=0;
        if(!protocol_error || rsp_valid || !req_ready) $fatal(1,"unsolicited idle return mishandled");
        reset_drained;
        issue_request(32'h600); // cancel before AR handshake
        reset_drained;
        issue_request(32'h800);
        @(negedge clk); axi_arready=1;
        @(posedge clk);
        @(negedge clk); axi_arready=0;
        reset_drained; // model cancels its scheduled return at the same time
        transaction(32'ha00,1,1,2,0,0);
        // Premature return before AR handshake must not be mistaken for this read.
        reset_drained;
        issue_request(32'hc00);
        @(negedge clk); axi_rvalid=1; axi_rdata=256'hbad; axi_rlast=1; axi_rid=0;
        @(posedge clk);
        @(negedge clk); axi_rvalid=0;
        if(!protocol_error || rsp_valid || !axi_arvalid) $fatal(1,"premature return consumed");
        @(negedge clk); axi_arready=1;
        @(posedge clk);
        @(negedge clk); axi_arready=0; axi_rvalid=1; axi_rdata=pattern(32'hc00);
        @(posedge clk);
        @(negedge clk); axi_rvalid=0;
        if(!rsp_valid || rsp_data !== pattern(32'hc00)) $fatal(1,"valid return after premature return lost");
        reset_drained; // cancel an already buffered response
        transaction(32'he00,1,0,20,0,0);
        if(requests != returns || outstanding != 0) $fatal(1,"final scoreboard imbalance");
        $display("PASS pango_read_bridge: %0d transactions; random AR/return delays, response stalls, errors, reset flush",checks);
        $finish;
    end
    initial begin #2000000; $fatal(1,"timeout"); end
endmodule

