`timescale 1ns/1ps
module tb_gamma;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;
    reg [1:0] cfg_mode=0;
    reg [2:0] cfg_bank=3;
    reg in_valid=0, in_sof=0, in_eof=0, out_ready=0;
    reg [23:0] in_rgb=0;
    wire in_ready, out_valid, out_sof, out_eof, stats_valid;
    wire [23:0] out_rgb;
    wire [2:0] out_bank;
    wire [39:0] stats_sum;
    wire [31:0] stats_count;
    gamma_stream dut(.*);
    reg [23:0] source [0:8191], expected [0:8191];
    reg [1:0] modes [0:8191]; reg [2:0] banks [0:8191], used [0:8191];
    reg sof [0:8191], eof [0:8191];
    reg [39:0] sums [0:8191]; reg [31:0] counts [0:8191];
    integer n, file_handle, scan, j, sent=0, received=0, stat_index=0, stat_frames=0, frames=0, cycles=0;
    reg stalled=0, accepted=0;
    reg [28:0] held;
    initial begin
        file_handle=$fopen("build/gamma_vectors.txt","r");
        if (!file_handle) $fatal(1,"missing gamma vectors");
        scan=$fscanf(file_handle,"%d\n",n);
        for (j=0;j<n;j=j+1) begin
            scan=$fscanf(file_handle,"%h %h %h %h %h %h %h %h %h\n",
                source[j],modes[j],banks[j],sof[j],eof[j],expected[j],used[j],sums[j],counts[j]);
            if(scan != 9) $fatal(1,"malformed vector %0d",j);
            if(eof[j]) frames=frames+1;
        end
        $fclose(file_handle);
        repeat(3) @(negedge clk);
        rst_n=1;
    end
    always @(negedge clk) if(rst_n) begin
        // Hold a pending source transaction until accepted; insert input bubbles.
        if (!in_valid || accepted) begin
            in_valid=sent<n && cycles%5 != 1;
            if(sent<n) begin
                in_rgb=source[sent]; cfg_mode=modes[sent]; cfg_bank=banks[sent];
                in_sof=sof[sent]; in_eof=eof[sent];
            end
        end
        out_ready=(cycles%11 != 2 && cycles%11 != 3 && cycles%11 != 4);
    end
    always @(posedge clk) if(rst_n) begin
        cycles=cycles+1;
        if(stalled && (!out_valid || {out_rgb,out_sof,out_eof,out_bank} !== held))
            $fatal(1,"output changed under stall");
        stalled=out_valid && !out_ready;
        held={out_rgb,out_sof,out_eof,out_bank};
        accepted=in_valid && in_ready;
        if(accepted) sent=sent+1;
        if(out_valid && out_ready) begin
            if(received>=n || out_rgb !== expected[received] || out_bank !== used[received] ||
               out_sof !== sof[received] || out_eof !== eof[received])
                $fatal(1,"pixel %0d rgb=%h expected=%h bank=%d expectedbank=%d",
                    received,out_rgb,expected[received],out_bank,used[received]);
            received=received+1;
        end
        if(stats_valid) begin
            while(stat_index<n && !eof[stat_index]) stat_index=stat_index+1;
            if(stat_index>=n || stats_sum !== sums[stat_index] || stats_count !== counts[stat_index])
                $fatal(1,"stats frame %0d sum=%d expected=%d count=%d expected=%d",
                    stat_frames,stats_sum,sums[stat_index],stats_count,counts[stat_index]);
            stat_frames=stat_frames+1; stat_index=stat_index+1;
        end
        if(received==n && stat_frames==frames) begin
            $display("PASS gamma %0d pixels %0d frames, stalls, frame configuration, coincident SOF/EOF",n,frames);
            $finish;
        end
        if(cycles>100000) $fatal(1,"timeout sent=%d received=%d",sent,received);
    end
endmodule
