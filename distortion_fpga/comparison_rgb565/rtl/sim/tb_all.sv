`timescale 1ns/1ps
`include "settings.vh"
module tb_all;
    localparam W=`TEST_WIDTH,H=`TEST_HEIGHT,N=`TEST_NODES,WF=`TEST_WEIGHT_FRAC;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;
    reg [95:0] rgb_vectors [0:`RGB_CASES-1];
    reg [223:0] signed_vectors [0:`SIGNED_CASES-1];
    reg [31:0] gamma_vectors [0:`GAMMA_CASES-1];
    reg gamma_ce=0,gamma_valid=0,gamma_enable=0;
    reg [15:0] gamma_in=0,gamma_meta=0;
    wire gamma_ov,gamma_identity_valid;
    wire [15:0] gamma_out,gamma_out_meta,gamma_identity,gamma_identity_meta;
    gamma_rgb565 #(.META_BITS(16),.LUT5_FILE("vectors/gamma5.memh"),.LUT6_FILE("vectors/gamma6.memh")) gamma_stage(
        .clk(clk),.rst_n(rst_n),.ce(gamma_ce),.in_valid(gamma_valid),.enable(gamma_enable),
        .in_pixel(gamma_in),.in_meta(gamma_meta),.out_valid(gamma_ov),.out_pixel(gamma_out),.out_meta(gamma_out_meta));
    gamma_rgb565 #(.META_BITS(16)) gamma_default(
        .clk(clk),.rst_n(rst_n),.ce(gamma_ce),.in_valid(gamma_valid),.enable(1'b1),
        .in_pixel(gamma_in),.in_meta(gamma_meta),.out_valid(gamma_identity_valid),.out_pixel(gamma_identity),.out_meta(gamma_identity_meta));
    reg [95:0] map0 [0:`QUERY_CASES-1],map1 [0:`QUERY_CASES-1];
    reg [48:0] eng0 [0:`QUERY_CASES-1],eng1 [0:`QUERY_CASES-1];
    reg [63:0] lut0 [0:N-1],lut1 [0:N-1];
    reg [15:0] expected0 [0:W*H-1],expected1 [0:W*H-1];
    reg valid0 [0:W*H-1],valid1 [0:W*H-1];
    reg unit_ce=0,p_valid=0,s_valid=0;
    reg [15:0] p00=0,p10=0,p01=0,p11=0;
    reg [7:0] fx=0,fy=0;
    wire p_out_valid;wire [15:0] p_out;
    reg signed [31:0] a00=0,a10=0,a01=0,a11=0;
    reg [WF:0] wx=0,wy=0;
    wire s_out_valid;wire signed [31:0] s_out;
    wire [32:0] delayed_tag;
    reg [31:0] tag=0;
    bilinear_rgb565 pixel(.clk(clk),.rst_n(rst_n),.ce(unit_ce),.in_valid(p_valid),
        .p00(p00),.p10(p10),.p01(p01),.p11(p11),.fx(fx),.fy(fy),.out_valid(p_out_valid),.out_pixel(p_out));
    bilinear_signed #(.FRAC_BITS(WF)) coordinate(.clk(clk),.rst_n(rst_n),.ce(unit_ce),.in_valid(s_valid),
        .a00(a00),.a10(a10),.a01(a01),.a11(a11),.wx(wx),.wy(wy),.out_valid(s_out_valid),.out_value(s_out));
    stream_delay #(.WIDTH(33),.STAGES(3)) sync_delay(.clk(clk),.rst_n(rst_n),.ce(unit_ce),
        .in_token({p_valid,tag}),.out_token(delayed_tag));

    reg cfg_begin=0,cfg_we=0,cfg_commit=0;
    reg [15:0] cfg_addr=0;reg [63:0] cfg_data=0;
    reg m_in_valid=0,m_out_ready=0,m_frame_start=0;
    reg [15:0] m_x=0,m_y=0;
    wire m_in_ready,m_out_valid,m_cfg_ready,m_cfg_error,m_active_ready,m_pending,m_frame_ready,m_bank;
    wire signed [31:0] m_sx,m_sy;
    grid_mapper #(.OUT_WIDTH(W),.OUT_HEIGHT(H),.GRID_LOG2(`TEST_LOG2),.WEIGHT_FRAC(WF)) mapper(
        .clk(clk),.rst_n(rst_n),.in_valid(m_in_valid),.in_ready(m_in_ready),.dst_x(m_x),.dst_y(m_y),
        .out_valid(m_out_valid),.out_ready(m_out_ready),.src_x_q(m_sx),.src_y_q(m_sy),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(m_cfg_ready),.cfg_error(m_cfg_error),.active_ready(m_active_ready),.pending(m_pending),
        .frame_start(m_frame_start),.frame_ready(m_frame_ready),.active_bank(m_bank));
    reg e_in_valid=0,e_out_ready=0,e_frame_start=0,e_sof=0,e_eol=0;
    reg [15:0] e_x=0,e_y=0;
    wire e_in_ready,e_out_valid,e_cfg_ready,e_cfg_error,e_active_ready,e_pending,e_frame_ready,e_bank,e_error,e_sample_valid;
    wire [15:0] e_pixel,e_out_x,e_out_y;wire e_out_sof,e_out_eol;
    wire e_req_valid,e_req_ready,e_rsp_valid,e_rsp_ready;
    wire [23:0] e_req_addr;wire [15:0] e_rsp_data;
    undistort_engine #(.SRC_WIDTH(W),.SRC_HEIGHT(H),.OUT_WIDTH(W),.OUT_HEIGHT(H),
        .GRID_LOG2(`TEST_LOG2),.WEIGHT_FRAC(WF),.USE_FAST_MAP(`TEST_USE_FAST_MAP)) engine(
        .clk(clk),.rst_n(rst_n),.in_valid(e_in_valid),.in_ready(e_in_ready),.dst_x(e_x),.dst_y(e_y),.in_sof(e_sof),.in_eol(e_eol),
        .out_valid(e_out_valid),.out_ready(e_out_ready),.out_pixel(e_pixel),.out_x(e_out_x),.out_y(e_out_y),
        .out_sof(e_out_sof),.out_eol(e_out_eol),.out_sample_valid(e_sample_valid),
        .mem_req_valid(e_req_valid),.mem_req_ready(e_req_ready),.mem_req_addr(e_req_addr),
        .mem_rsp_valid(e_rsp_valid),.mem_rsp_ready(e_rsp_ready),.mem_rsp_data(e_rsp_data),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(e_cfg_ready),.cfg_error(e_cfg_error),.active_ready(e_active_ready),.pending(e_pending),
        .frame_start(e_frame_start),.frame_ready(e_frame_ready),.active_bank(e_bank),.protocol_error(e_error));
    tb_memory #(.WIDTH(W),.HEIGHT(H),.SEED(32'h3141592)) engine_memory(
        .clk(clk),.rst_n(rst_n),.req_valid(e_req_valid),.req_ready(e_req_ready),.req_addr(e_req_addr),
        .rsp_valid(e_rsp_valid),.rsp_ready(e_rsp_ready),.rsp_data(e_rsp_data));

    reg f_start=0,f_wr_ready=0;
    wire f_start_ready,f_busy,f_done,f_error,f_cfg_ready,f_cfg_error,f_pending,f_active_ready,f_bank;
    wire [31:0] f_invalid;
    wire f_req_valid,f_req_ready,f_rsp_valid,f_rsp_ready,f_wr_valid;
    wire [23:0] f_req_addr,f_wr_addr;wire [15:0] f_rsp_data,f_wr_data;
    remap_frame_writer #(.SRC_WIDTH(W),.SRC_HEIGHT(H),.OUT_WIDTH(W),.OUT_HEIGHT(H),
        .GRID_LOG2(`TEST_LOG2),.WEIGHT_FRAC(WF),.USE_FAST_MAP(`TEST_USE_FAST_MAP)) writer(
        .clk(clk),.rst_n(rst_n),.start(f_start),.start_ready(f_start_ready),.busy(f_busy),.done(f_done),
        .invalid_pixels(f_invalid),.protocol_error(f_error),
        .mem_req_valid(f_req_valid),.mem_req_ready(f_req_ready),.mem_req_addr(f_req_addr),
        .mem_rsp_valid(f_rsp_valid),.mem_rsp_ready(f_rsp_ready),.mem_rsp_data(f_rsp_data),
        .wr_valid(f_wr_valid),.wr_ready(f_wr_ready),.wr_addr(f_wr_addr),.wr_data(f_wr_data),
        .cfg_begin(cfg_begin),.cfg_we(cfg_we),.cfg_commit(cfg_commit),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
        .cfg_ready(f_cfg_ready),.cfg_error(f_cfg_error),.pending(f_pending),.active_ready(f_active_ready),.active_bank(f_bank));
    tb_memory #(.WIDTH(W),.HEIGHT(H),.SEED(32'h2718281)) frame_memory(
        .clk(clk),.rst_n(rst_n),.req_valid(f_req_valid),.req_ready(f_req_ready),.req_addr(f_req_addr),
        .rsp_valid(f_rsp_valid),.rsp_ready(f_rsp_ready),.rsp_data(f_rsp_data));

    reg [31:0] rng=32'h934827;
    task tick_random;
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    endtask
    task reset_all;
        @(negedge clk);rst_n=0;p_valid=0;s_valid=0;m_in_valid=0;e_in_valid=0;f_start=0;gamma_valid=0;unit_ce=0;gamma_ce=0;
        cfg_begin=0;cfg_we=0;cfg_commit=0;m_frame_start=0;e_frame_start=0;
        repeat(4) @(posedge clk);
        @(negedge clk);rst_n=1;
        @(posedge clk);#1;
        if(m_active_ready || e_active_ready || f_active_ready) $fatal(1,"reset incorrectly validated a RAM bank");
        if(p_out_valid || s_out_valid || gamma_ov || e_out_valid || f_busy)
            $fatal(1,"reset retained a valid token/busy state");
    endtask
    task test_gamma;
        integer sent,cycles,mode;
        reg [15:0] expected,held_pixel,held_meta;
        reg held_valid;
        // Each of all 65536 codes is checked both with Gamma and with bypass.
        for(mode=0;mode<2;mode=mode+1)begin
            sent=0;cycles=0;gamma_enable=mode;
            while(sent<`GAMMA_CASES)begin
                @(negedge clk);tick_random();gamma_ce=rng[0];gamma_valid=rng[1];
                gamma_in=gamma_vectors[sent][31:16];gamma_meta=sent;
                expected=mode ? gamma_vectors[sent][15:0] : gamma_in;
                held_pixel=gamma_out;held_meta=gamma_out_meta;held_valid=gamma_ov;
                @(posedge clk);#1;
                if(gamma_ce)begin
                    if(gamma_ov!==gamma_valid || gamma_out_meta!==gamma_meta || gamma_out!==expected)
                        $fatal(1,"Gamma pipeline mismatch code=%h mode=%0d",gamma_in,mode);
                    if(gamma_identity_valid!==gamma_valid || gamma_identity!==gamma_in || gamma_identity_meta!==gamma_meta)
                        $fatal(1,"empty Gamma tables did not preserve identity");
                    if(gamma_valid)sent=sent+1;
                end else if(gamma_out!==held_pixel || gamma_out_meta!==held_meta || gamma_ov!==held_valid)
                    $fatal(1,"Gamma CE hold mismatch");
                cycles=cycles+1;if(cycles>1000000)$fatal(1,"Gamma timeout");
            end
        end
        @(negedge clk);gamma_valid=0;gamma_ce=1;
        $display("PASS Gamma: %0d codes each in enabled/bypass/identity modes",`GAMMA_CASES);
    endtask
    task load_table(input integer which);
        integer i;
        @(negedge clk);cfg_begin=1;
        @(negedge clk);cfg_begin=0;
        for(i=0;i<N;i=i+1) begin
            if(!m_cfg_ready || !e_cfg_ready || !f_cfg_ready) $fatal(1,"configuration unexpectedly blocked");
            cfg_we=1;cfg_addr=i;cfg_data=which==0 ? lut0[i] : lut1[i];
            @(negedge clk);
        end
        cfg_we=0;cfg_commit=1;
        @(negedge clk);cfg_commit=0;
        if(!m_pending || !e_pending || !f_pending) $fatal(1,"complete configuration did not become pending");
        if(m_cfg_error || e_cfg_error || f_cfg_error) $fatal(1,"valid configuration produced error");
    endtask
    task activate_points;
        if(!m_frame_ready || !e_frame_ready) $fatal(1,"activation attempted without frame readiness");
        @(negedge clk);m_frame_start=1;e_frame_start=1;
        @(negedge clk);m_frame_start=0;e_frame_start=0;
        if(!m_active_ready || !e_active_ready) $fatal(1,"frame boundary did not activate map");
    endtask
    task test_units;
        integer sent_p,sent_s,received_p,received_s,cycles,ip,is;
        reg [2:0] vp,vs;
        reg [15:0] qp[0:2];reg [31:0] qs[0:2],qt[0:2];
        reg [15:0] previous_p;reg [31:0] previous_s;
        reg previous_pv,previous_sv;
        sent_p=0;sent_s=0;received_p=0;received_s=0;cycles=0;vp=0;vs=0;
        for(ip=0;ip<3;ip=ip+1) begin qp[ip]=0;qs[ip]=0;qt[ip]=0;end
        while(received_p<`RGB_CASES || received_s<`SIGNED_CASES) begin
            @(negedge clk);tick_random();unit_ce=rng[0];
            p_valid=sent_p<`RGB_CASES && rng[1];s_valid=sent_s<`SIGNED_CASES && rng[2];
            if(p_valid) begin
                {p00,p10,p01,p11,fx,fy}=rgb_vectors[sent_p][95:16];tag=sent_p;
            end
            if(s_valid) begin
                a00=signed_vectors[sent_s][223:192];a10=signed_vectors[sent_s][191:160];
                a01=signed_vectors[sent_s][159:128];a11=signed_vectors[sent_s][127:96];
                wx=signed_vectors[sent_s][95:64];wy=signed_vectors[sent_s][63:32];
            end
            previous_p=p_out;previous_s=s_out;previous_pv=p_out_valid;previous_sv=s_out_valid;
            @(posedge clk);
            if(unit_ce) begin
                vp={vp[1:0],p_valid};vs={vs[1:0],s_valid};
                qp[2]=qp[1];qp[1]=qp[0];qp[0]=p_valid ? rgb_vectors[sent_p][15:0] : 0;
                qs[2]=qs[1];qs[1]=qs[0];qs[0]=s_valid ? signed_vectors[sent_s][31:0] : 0;
                qt[2]=qt[1];qt[1]=qt[0];qt[0]=tag;
                if(p_valid)sent_p=sent_p+1;
                if(s_valid)sent_s=sent_s+1;
            end
            #1;
            if(p_out_valid!==vp[2] || s_out_valid!==vs[2]) $fatal(1,"pipeline valid latency mismatch");
            if(delayed_tag!=={vp[2],qt[2]}) $fatal(1,"data/metadata latency mismatch");
            if(unit_ce) begin
                if(p_out_valid) begin
                    if(p_out!==qp[2]) $fatal(1,"RGB565 mismatch %d got %h expected %h",received_p,p_out,qp[2]);
                    received_p=received_p+1;
                end
                if(s_out_valid) begin
                    if(s_out!==qs[2]) $fatal(1,"signed mismatch %d got %h expected %h",received_s,s_out,qs[2]);
                    received_s=received_s+1;
                end
            end else if(p_out!==previous_p || s_out!==previous_s || p_out_valid!==previous_pv || s_out_valid!==previous_sv)
                $fatal(1,"clock enable did not hold pipeline");
            cycles=cycles+1;if(cycles>100000) $fatal(1,"unit tests timed out");
        end
        @(negedge clk);p_valid=0;s_valid=0;unit_ce=1;
        repeat(5)@(negedge clk);
        $display("PASS units: RGB=%0d signed=%0d weight_frac=%0d",received_p,received_s,WF);
    endtask
    task mapper_point(input reg [95:0] vector);
        integer timeout,stall;
        reg signed [31:0] hold_x,hold_y;
        @(negedge clk);m_x=vector[95:80];m_y=vector[79:64];m_in_valid=1;m_out_ready=0;
        timeout=0;
        do begin @(posedge clk);timeout=timeout+1;if(timeout>200)$fatal(1,"mapper request timeout");end while(!m_in_ready);
        @(negedge clk);m_in_valid=0;
        timeout=0;
        while(!m_out_valid) begin @(negedge clk);timeout=timeout+1;if(timeout>200)$fatal(1,"mapper output timeout");end
        if(m_sx!==vector[63:32] || m_sy!==vector[31:0]) $fatal(1,"map mismatch dst=(%d,%d) got=(%h,%h) expected=(%h,%h)",m_x,m_y,m_sx,m_sy,vector[63:32],vector[31:0]);
        hold_x=m_sx;hold_y=m_sy;
        tick_random();stall=rng[3:1];
        repeat(stall) begin @(negedge clk);if(!m_out_valid || m_sx!==hold_x || m_sy!==hold_y)$fatal(1,"mapper dropped stalled result");end
        m_out_ready=1;@(negedge clk);m_out_ready=0;
    endtask
    task engine_point(input reg [48:0] vector,input integer tag_index);
        integer timeout,stall,initial_reads;
        reg [15:0] hold_pixel;
        initial_reads=engine_memory.read_count;
        @(negedge clk);e_x=vector[48:33];e_y=vector[32:17];e_sof=tag_index%7==0;e_eol=tag_index%5==0;
        e_in_valid=1;e_out_ready=0;timeout=0;
        do begin @(posedge clk);timeout=timeout+1;if(timeout>200)$fatal(1,"engine request timeout");end while(!e_in_ready);
        @(negedge clk);e_in_valid=0;timeout=0;
        while(!e_out_valid) begin @(negedge clk);timeout=timeout+1;if(timeout>500)$fatal(1,"engine output timeout");end
        if(e_pixel!==vector[16:1] || e_sample_valid!==vector[0]) $fatal(1,"pixel mismatch dst=(%d,%d) got=%h/%b expected=%h/%b",e_x,e_y,e_pixel,e_sample_valid,vector[16:1],vector[0]);
        if(engine_memory.read_count-initial_reads!==(vector[0] ? 4 : 0))
            $fatal(1,"valid/invalid sample performed unexpected number of memory reads");
        if(e_out_x!==e_x || e_out_y!==e_y || e_out_sof!==e_sof || e_out_eol!==e_eol) $fatal(1,"pixel tag corrupted");
        hold_pixel=e_pixel;tick_random();stall=rng[3:1];
        repeat(stall)begin @(negedge clk);if(!e_out_valid || e_pixel!==hold_pixel)$fatal(1,"engine dropped stalled pixel");end
        e_out_ready=1;@(negedge clk);e_out_ready=0;
    endtask
    task render_frame(input integer which);
        integer count,cycles,invalid_count,initial_reads;
        reg [15:0] expected,held_data;
        reg [23:0] held_address;
        reg previously_stalled;
        initial_reads=frame_memory.read_count;
        @(negedge clk);if(!f_start_ready)$fatal(1,"frame start unexpectedly unavailable");f_start=1;
        @(negedge clk);f_start=0;count=0;cycles=0;invalid_count=0;previously_stalled=0;
        while(!f_done)begin
            tick_random();f_wr_ready=rng[0];
            if(previously_stalled && (!f_wr_valid || f_wr_data!==held_data || f_wr_addr!==held_address))$fatal(1,"write token changed while stalled");
            previously_stalled=f_wr_valid && !f_wr_ready;held_data=f_wr_data;held_address=f_wr_addr;
            if(f_wr_valid && f_wr_ready)begin
                expected=which==0 ? expected0[count] : expected1[count];
                if(f_wr_addr!==count || f_wr_data!==expected)$fatal(1,"frame mismatch idx=%d addr=%d got=%h expected=%h",count,f_wr_addr,f_wr_data,expected);
                if(which==0 ? !valid0[count] : !valid1[count])invalid_count=invalid_count+1;
                count=count+1;
            end
            @(posedge clk);#1;cycles=cycles+1;
            if(cycles>200000)$fatal(1,"frame render timeout");
            if(!f_done)@(negedge clk);
        end
        if(count!=W*H || f_invalid!==invalid_count || f_busy)$fatal(1,"frame completion/accounting mismatch");
        if(frame_memory.read_count-initial_reads!==4*(count-invalid_count))$fatal(1,"frame memory read accounting mismatch");
        @(negedge clk);f_wr_ready=0;
        $display("PASS frame %0d: pixels=%0d invalid=%0d cycles=%0d",which,count,invalid_count,cycles);
    endtask
    integer i;
    initial begin
        $readmemh("vectors/rgb.memh",rgb_vectors);$readmemh("vectors/signed.memh",signed_vectors);
        $readmemh("vectors/gamma_expected.memh",gamma_vectors);
        $readmemh("vectors/mapper0.memh",map0);$readmemh("vectors/mapper1.memh",map1);
        $readmemh("vectors/engine0.memh",eng0);$readmemh("vectors/engine1.memh",eng1);
        $readmemh("vectors/map0.memh",lut0);$readmemh("vectors/map1.memh",lut1);
        $readmemh("vectors/frame0_expected.memh",expected0);$readmemh("vectors/frame1_expected.memh",expected1);
        $readmemh("vectors/frame0_valid.memh",valid0);$readmemh("vectors/frame1_valid.memh",valid1);
        reset_all();test_units();test_gamma();
        load_table(0);activate_points();
        for(i=0;i<`QUERY_CASES;i=i+1)mapper_point(map0[i]);
        for(i=0;i<`QUERY_CASES;i=i+1)engine_point(eng0[i],i);
        render_frame(0);
        // Reject incomplete commit, then reject out-of-order node writes.
        @(negedge clk);cfg_begin=1;@(negedge clk);cfg_begin=0;cfg_we=1;cfg_addr=0;cfg_data=lut1[0];
        @(negedge clk);cfg_we=0;cfg_commit=1;@(negedge clk);cfg_commit=0;
        if(!m_cfg_error || !e_cfg_error || !f_cfg_error || m_pending)$fatal(1,"incomplete LUT accepted");
        @(negedge clk);cfg_begin=1;@(negedge clk);cfg_begin=0;cfg_we=1;cfg_addr=2;
        @(negedge clk);cfg_we=0;
        if(!m_cfg_error || !e_cfg_error || !f_cfg_error)$fatal(1,"out-of-order LUT accepted");
        // Load new bank while mapper has an old result in flight/backpressured.
        @(negedge clk);m_x=map0[3][95:80];m_y=map0[3][79:64];m_in_valid=1;m_out_ready=0;
        @(posedge clk);if(!m_in_ready)$fatal(1,"expected mapper readiness");
        @(negedge clk);m_in_valid=0;
        load_table(1);
        if(m_frame_ready)$fatal(1,"mapper reports idle with held result");
        @(negedge clk);m_frame_start=1;@(negedge clk);m_frame_start=0;
        if(!m_bank || !m_pending || m_sx!==map0[3][63:32] || m_sy!==map0[3][31:0])$fatal(1,"bank switched mid-token");
        m_out_ready=1;@(negedge clk);m_out_ready=0;
        mapper_point(map0[4]);engine_point(eng0[4],4);
        activate_points();
        if(m_bank || e_bank)$fatal(1,"second bank not activated");
        for(i=0;i<`QUERY_CASES;i=i+1)mapper_point(map1[i]);
        for(i=0;i<`QUERY_CASES;i=i+1)engine_point(eng1[i],i);
        render_frame(1);
        if(f_bank)$fatal(1,"frame writer did not flip bank on boundary");
        load_table(0);activate_points();mapper_point(map0[4]);engine_point(eng0[4],4);render_frame(0);
        // Start overwriting inactive bank, reset, require complete reloading.
        @(negedge clk);cfg_begin=1;@(negedge clk);cfg_begin=0;cfg_we=1;cfg_addr=0;cfg_data=lut1[0];
        @(negedge clk);cfg_we=0;
        // Abort a pixel with a source-memory request outstanding. Adapter and
        // core share reset, so no old response may enter the next frame.
        e_x=0;e_y=0;e_in_valid=1;e_out_ready=0;
        @(posedge clk);if(!e_in_ready)$fatal(1,"reset-in-flight request blocked");
        @(negedge clk);e_in_valid=0;
        do @(posedge clk); while(!(e_req_valid && e_req_ready));
        reset_all();
        if(m_pending || e_pending || f_pending)$fatal(1,"reset retained pending configuration");
        load_table(0);activate_points();mapper_point(map0[0]);engine_point(eng0[0],0);render_frame(0);
        if(e_error || f_error)$fatal(1,"unexpected protocol error");
        $display("ALL_RTL_TESTS_PASSED weight_frac=%0d fast_engine=%0d",WF,`TEST_USE_FAST_MAP);
        $finish;
    end
    initial begin #100000000;$fatal(1,"global timeout");end
endmodule
