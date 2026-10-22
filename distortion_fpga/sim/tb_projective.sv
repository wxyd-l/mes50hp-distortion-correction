`timescale 1ns/1ps
module tb_projective;
    localparam N=64*48, CASES=4, DIV_CASES=256;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=1,n_valid=0,m_valid=0;
    reg [31:0] cfg[0:16];
    reg [31:0] parameters_mem[0:5*17-1];
    reg [63:0] expected[0:CASES*N-1];
    reg [31:0] divider[0:DIV_CASES*10-1];
    reg [31:0] guarded_errors[0:DIV_CASES-1];
    reg [15:0] u=0,v=0;
    wire n_ready,n_out,n_error,m_ready,m_out,m_error;
    wire [15:0] nu,nv,mu,mv;
    wire signed [31:0] nx,ny,mx,my;
    wire g_ready,g_out,g_error;
    wire [15:0] gu,gv;
    wire signed [31:0] gx,gy;
    reg [31:0] rng=32'h5409abcd;
    integer ni=0,n_received=0,g_received=0,mi=0,m_received=0,i,j,cycles=0;
    reg held_n=0,held_m=0;
    reg [96:0] saved_n,saved_m;
    homography_normalizer normalizer (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(n_valid),.in_ready(n_ready),.in_u(u),.in_v(v),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .a20(cfg[14]),.a21(cfg[15]),.a22(cfg[16]),
        .out_valid(n_out),.out_overflow(n_error),.out_u(nu),.out_v(nv),.norm_x(nx),.norm_y(ny)
    );
    homography_normalizer #(.POSITIVE_DEPTH(1)) guarded_normalizer (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(n_valid),.in_ready(g_ready),.in_u(u),.in_v(v),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .a20(cfg[14]),.a21(cfg[15]),.a22(cfg[16]),
        .out_valid(g_out),.out_overflow(g_error),.out_u(gu),.out_v(gv),.norm_x(gx),.norm_y(gy)
    );
    projective_distortion_mapper mapper (
        .clk(clk),.rst_n(rst_n),.ce(ce),.in_valid(m_valid),.in_ready(m_ready),.in_u(u),.in_v(v),
        .a00(cfg[0]),.a01(cfg[1]),.a02(cfg[2]),.a10(cfg[3]),.a11(cfg[4]),.a12(cfg[5]),
        .a20(cfg[14]),.a21(cfg[15]),.a22(cfg[16]),
        .k1(cfg[6]),.k2(cfg[7]),.p1(cfg[8]),.p2(cfg[9]),
        .fx(cfg[10]),.fy(cfg[11]),.cx(cfg[12]),.cy(cfg[13]),
        .out_valid(m_out),.out_overflow(m_error),.out_u(mu),.out_v(mv),.src_x(mx),.src_y(my)
    );
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        ce=(rng[2:0]!=0);
    end
    always @(posedge clk) begin
        if(!rst_n) begin held_n<=0;held_m<=0;end
        else begin
            cycles=cycles+1;
            if(cycles>2000000) $fatal(1,"Projective test timeout");
            if(held_n && (!n_out || {n_error,nu,nv,nx,ny}!==saved_n))
                $fatal(1,"Normalizer output changed while ce=0");
            if(held_m && (!m_out || {m_error,mu,mv,mx,my}!==saved_m))
                $fatal(1,"Projective output changed while ce=0");
            held_n<=n_out&&!ce;held_m<=m_out&&!ce;
            saved_n<={n_error,nu,nv,nx,ny};saved_m<={m_error,mu,mv,mx,my};
            if(ce && n_out) begin
                if(n_error!==divider[ni*10+7][0] || nu!==divider[ni*10][15:0] || nv!==0)
                    $fatal(1,"Divider status/token mismatch case=%0d",ni);
                if(!n_error && ({nx,ny}!=={divider[ni*10+8],divider[ni*10+9]}))
                    $fatal(1,"Divider quotient case=%0d got=%h,%h expected=%h,%h",ni,nx,ny,divider[ni*10+8],divider[ni*10+9]);
                n_received=n_received+1;
            end
            if(ce && g_out) begin
                if(g_error!==guarded_errors[ni][0] || gu!==divider[ni*10][15:0] || gv!==0)
                    $fatal(1,"Positive-depth guard status/token mismatch case=%0d",ni);
                if(!g_error && {gx,gy}!=={divider[ni*10+8],divider[ni*10+9]})
                    $fatal(1,"Positive-depth guard changed valid quotient case=%0d",ni);
                g_received=g_received+1;
            end
            if(ce && m_out) begin
                if(m_error || mu!==m_received%64 || mv!==m_received/64 ||
                   {mx,my}!==expected[mi*N+m_received])
                    $fatal(1,"Projective coordinate case=%0d pixel=%0d got=%h,%h expected=%h overflow=%0b",mi,m_received,mx,my,expected[mi*N+m_received],m_error);
                m_received=m_received+1;
            end
        end
    end
    initial begin
        $readmemh("build/projective/parameters.mem",parameters_mem);
        $readmemh("build/projective/coordinates.mem",expected);
        $readmemh("build/projective/divider.mem",divider);
        $readmemh("build/projective/guarded_errors.mem",guarded_errors);
        for(i=0;i<17;i=i+1) cfg[i]=0;
        repeat(4) @(negedge clk);
        #1 rst_n=1;
        for(ni=0;ni<DIV_CASES;ni=ni+1) begin
            @(negedge clk);#1;
            u=divider[ni*10];v=0;
            cfg[0]=divider[ni*10+1];cfg[2]=divider[ni*10+2];
            cfg[3]=divider[ni*10+3];cfg[5]=divider[ni*10+4];
            cfg[14]=divider[ni*10+5];cfg[16]=divider[ni*10+6];
            n_valid=1;
            @(posedge clk);while(!n_ready) @(posedge clk);
            @(negedge clk);#1 n_valid=0;
            wait(n_received==ni+1 && g_received==ni+1);
        end
        $display("PASS restoring divider: %0d signed/zero/overflow/stalled tokens",DIV_CASES);
        $display("PASS positive-depth guard: %0d matched tokens including negative-depth rejection",DIV_CASES);
        for(mi=0;mi<CASES;mi=mi+1) begin
            @(negedge clk);#1;
            for(i=0;i<17;i=i+1) cfg[i]=parameters_mem[mi*17+i];
            m_received=0;
            for(j=0;j<N;j=j+1) begin
                u=j%64;v=j/64;m_valid=1;
                @(posedge clk);while(!m_ready) @(posedge clk);
                @(negedge clk);#1;
            end
            m_valid=0;
            wait(m_received==N);
            @(negedge clk);#1;
            $display("PASS projective coordinate case=%0d pixels=%0d",mi,m_received);
        end
        $display("PASS tb_projective: exact homogeneous quotient and Brown-Conrady coordinates");
        $finish;
    end
endmodule
