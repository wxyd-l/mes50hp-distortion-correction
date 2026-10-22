`timescale 1ns/1ps
// Enhanced source frames are written into a memory model, then fetched through
// the real projective mapper, bilinear core, cache and Pango read bridge.
module tb_algorithm_pipeline;
    localparam W=32,H=24,N=W*H,CASES=10;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,start=0;
    reg [31:0] cfg[0:16];
    reg [31:0] parameters_mem[0:CASES*17-1];
    reg [23:0] raw_mem[0:CASES*N-1],enhanced_mem[0:CASES*N-1],expected_mem[0:CASES*N-1];
    reg [7:0] control_mem[0:CASES-1];
    reg [71:0] statistics_mem[0:CASES-1];
    reg [23:0] source[0:N-1];
    reg [1:0] gamma_mode=0;
    reg [2:0] gamma_bank=3;
    reg in_valid=0,in_sof=0,in_eof=0;
    reg [23:0] in_rgb=0;
    wire in_ready,gamma_valid,gamma_sof,gamma_eof,stats_valid;
    wire [23:0] gamma_rgb;
    wire [2:0] applied_bank;
    wire [39:0] stats_sum;
    wire [31:0] stats_count;
    reg gamma_ready=0;
    wire busy,done,start_ready,frame_overflow,memory_error,out_valid,out_last;
    wire [23:0] out_rgb;
    wire [15:0] out_u,out_v;
    wire [31:0] frame_cycles,pixels_emitted,hits,misses;
    wire [27:0] araddr;
    wire [3:0] arlen,arid;
    wire arvalid;
    reg arready=0,rvalid=0,out_ready=0;
    reg [255:0] rdata=0;
    reg [31:0] rng=32'h1eca7c11;
    integer frame=0,tx=0,produced=0,received=0,statistics_seen=0;
    integer pending=0,pending_word=0,delay_left=0,requests=0,cycles=0,i,lane;
    reg input_accepted=0,stalled_output=0,stalled_gamma=0;
    reg [56:0] held_output;
    reg [28:0] held_gamma;

    gamma_stream preprocessor (
        .clk(clk),.rst_n(rst_n),.cfg_mode(gamma_mode),.cfg_bank(gamma_bank),
        .in_valid(in_valid),.in_ready(in_ready),.in_rgb(in_rgb),.in_sof(in_sof),.in_eof(in_eof),
        .out_valid(gamma_valid),.out_ready(gamma_ready),.out_rgb(gamma_rgb),
        .out_sof(gamma_sof),.out_eof(gamma_eof),.out_bank(applied_bank),
        .stats_valid(stats_valid),.stats_sum(stats_sum),.stats_count(stats_count)
    );
    remap_ddr_read_top #(.WIDTH(W),.HEIGHT(H),.CACHE_LINES(64),.PROJECTIVE(1),.POSITIVE_DEPTH(1)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.start_ready(start_ready),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .k1(cfg[6]),.k2(cfg[7]),.p1(cfg[8]),.p2(cfg[9]),.fx(cfg[10]),.fy(cfg[11]),.cx(cfg[12]),.cy(cfg[13]),
        .a20(cfg[14]),.a21(cfg[15]),.a22(cfg[16]),
        .busy(busy),.done(done),.frame_overflow(frame_overflow),.memory_error(memory_error),
        .frame_cycles(frame_cycles),.pixels_emitted(pixels_emitted),.cache_hits(hits),.cache_misses(misses),
        .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_u(out_u),.out_v(out_v),.out_last(out_last),
        .axi_araddr(araddr),.axi_arlen(arlen),.axi_arid(arid),.axi_arvalid(arvalid),.axi_arready(arready),
        .axi_rdata(rdata),.axi_rid(4'd0),.axi_rvalid(rvalid),.axi_rlast(1'b1)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            input_accepted=0; pending<=0;rvalid<=0;
            stalled_output<=0;stalled_gamma<=0;
        end else begin
            input_accepted=in_valid&&in_ready;
            if(input_accepted) tx=tx+1;
            if(stalled_gamma && (!gamma_valid || {gamma_sof,gamma_eof,applied_bank,gamma_rgb}!==held_gamma))
                $fatal(1,"Gamma output changed under backpressure");
            stalled_gamma<=gamma_valid&&!gamma_ready;
            held_gamma<={gamma_sof,gamma_eof,applied_bank,gamma_rgb};
            if(gamma_valid&&gamma_ready) begin
                if(produced>=N || gamma_rgb!==enhanced_mem[frame*N+produced] || applied_bank!==control_mem[frame][2:0])
                    $fatal(1,"Gamma mismatch frame=%0d pixel=%0d",frame,produced);
                if(gamma_sof!==(produced==0) || gamma_eof!==(produced==N-1))
                    $fatal(1,"Gamma marker mismatch");
                source[produced]<=gamma_rgb;
                produced=produced+1;
            end
            if(stats_valid) begin
                statistics_seen=statistics_seen+1;
                if({stats_sum,stats_count}!==statistics_mem[frame])
                    $fatal(1,"Raw-source statistics mismatch frame=%0d",frame);
            end
            if(arvalid&&arready) begin
                if(pending || rvalid || araddr>=N || araddr[2:0]!=0 || arlen!=0 || arid!=0)
                    $fatal(1,"Bad Pango request frame=%0d addr=%h",frame,araddr);
                pending<=1;pending_word<=araddr;delay_left<=rng[11:8];requests=requests+1;
            end
            rvalid<=0;
            if(pending) begin
                if(delay_left==0) begin
                    for(lane=0;lane<8;lane=lane+1)
                        rdata[lane*32+:32]<={8'd0,source[pending_word+lane]};
                    rvalid<=1;pending<=0;
                end else delay_left<=delay_left-1;
            end
            if(stalled_output && (!out_valid || {out_last,out_u,out_v,out_rgb}!==held_output))
                $fatal(1,"Remap output changed under backpressure");
            stalled_output<=out_valid&&!out_ready;
            held_output<={out_last,out_u,out_v,out_rgb};
            if(out_valid&&out_ready) begin
                if(received>=N || out_u!==received%W || out_v!==received/W || out_last!==(received==N-1))
                    $fatal(1,"Output ordering mismatch frame=%0d pixel=%0d",frame,received);
                if(out_rgb!==expected_mem[frame*N+received])
                    $fatal(1,"Full-chain RGB mismatch frame=%0d pixel=%0d got=%h expected=%h",
                           frame,received,out_rgb,expected_mem[frame*N+received]);
                received=received+1;
            end
        end
    end
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        gamma_ready=(rng[2:0]!=0);
        arready=(rng[5:3]!=0);
        out_ready=(rng[9:6]>4);
    end
    initial begin
        $readmemh("build/pipeline/parameters.mem",parameters_mem);
        $readmemh("build/pipeline/raw.mem",raw_mem);
        $readmemh("build/pipeline/enhanced.mem",enhanced_mem);
        $readmemh("build/pipeline/corrected.mem",expected_mem);
        $readmemh("build/pipeline/control.mem",control_mem);
        $readmemh("build/pipeline/statistics.mem",statistics_mem);
        for(i=0;i<17;i=i+1) cfg[i]=0;
        repeat(5) @(negedge clk);
        rst_n=1;
        for(frame=0;frame<CASES;frame=frame+1) begin
            gamma_mode=control_mem[frame][7:6];gamma_bank=control_mem[frame][5:3];
            tx=0;produced=0;received=0;statistics_seen=0;requests=0;cycles=0;
            while(produced<N) begin
                if(!in_valid||input_accepted) begin
                    in_valid=tx<N && rng[14:12]!=0;
                    in_rgb=tx<N ? raw_mem[frame*N+tx] : 24'd0;
                    in_sof=tx==0;in_eof=tx==N-1;
                end
                // All configuration changes after SOF must wait for the next frame.
                if(tx>0) begin gamma_mode=0;gamma_bank=6;end
                @(negedge clk);
                cycles=cycles+1;
                if(cycles>20000) $fatal(1,"Preprocessor timeout");
            end
            in_valid=0;
            if(tx!=N || statistics_seen!=1 || gamma_valid) $fatal(1,"Preprocessor completion mismatch");
            for(i=0;i<17;i=i+1) cfg[i]=parameters_mem[frame*17+i];
            if(!start_ready) $fatal(1,"Remapper not ready for completed source frame");
            start=1;@(negedge clk);start=0;cycles=0;
            while(!done) begin
                @(negedge clk);cycles=cycles+1;
                if(cycles==30) for(i=0;i<17;i=i+1) cfg[i]=32'h5a5a5a5a;
                if(cycles>200000) $fatal(1,"Full-chain timeout");
            end
            if(received!=N || pixels_emitted!=N || busy || pending || rvalid || memory_error || frame_overflow)
                $fatal(1,"Full-chain completion mismatch");
            $display("PASS full-chain frame=%0d bank=%0d pixels=%0d DDR_reads=%0d remap_cycles=%0d",
                     frame,control_mem[frame][2:0],received,requests,frame_cycles);
            repeat(3) @(negedge clk);
        end
        $display("PASS tb_algorithm_pipeline: %0d pixels, Gamma -> source memory -> perspective -> Brown-Conrady -> cache -> bilinear",CASES*N);
        $finish;
    end
endmodule
