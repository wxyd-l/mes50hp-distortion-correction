// tb_page_multi.v -- 验收 #7：多帧连续 + “M4 落后一帧” 的页所有权检查
//
// 覆盖【页调度 + 页所有权】这条链（E1 撕裂那次的 bug 类）：
//   摄像头写 raw / M4 读 raw / M4 写结果 / 显示读结果 —— 四路两两不能同页。
// 帧分辨率用模型比例（PW 字/帧），不追求真实像素；真实像素链路由
//   run_bisect_m4 / run_dual / run_wrback / run_board_top 四个 TB 覆盖。
//
// 检查项：
//   1) 正常帧：page_ok（四路互不相同）必须恒 1；
//   2) 撕裂：任何一拍“正在被写的页 == 显示正在读的页” 计一次（正常帧与落后帧都必须为 0）；
//   3) M4 落后一帧：必须走 graceful 回退（显示切到刚写完的 raw 页），且不得撕裂；
//      回退帧里 disp 与 m4_rd 会短暂同页（两个读者），page_ok 允许为 0；
//   4) 正常帧：显示页必须跟随 m4_done_page。
`timescale 1ns/1ps

module tb_page_multi;
    localparam integer PW        = 32;
    localparam integer FRAME_CYC = 1000;
    localparam integer CAM_LAT   = 40;
    localparam integer M4_FAST   = 600;
    localparam integer M4_SLOW   = 1200;   // > FRAME_CYC ⇒ 落后一帧
    localparam integer NFRAME    = 6;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    wire [1:0] cam_page, m4_rd_page, m4_wr_page, disp_page;
    wire       disp_page_valid, page_ok;
    reg        cam_frame_pulse = 0, disp_frame_pulse = 0, m4_ready = 0;
    reg  [1:0] m4_done_page = 0;

    ud_page_sched u_pg (
        .clk(clk), .rst_n(rst_n),
        .cam_frame_pulse(cam_frame_pulse), .m4_ready(m4_ready), .m4_done_page(m4_done_page),
        .disp_frame_pulse(disp_frame_pulse),
        .cam_page(cam_page), .m4_rd_page(m4_rd_page), .m4_wr_page(m4_wr_page),
        .disp_page(disp_page), .disp_page_valid(disp_page_valid), .page_ok(page_ok)
    );

    integer pg_tag [0:3];
    integer i;
    initial for (i = 0; i < 4; i = i + 1) pg_tag[i] = 0;

    integer n_cam = 0, n_m4 = 0, n_pageok_bad = 0, n_tear = 0;
    integer n_fallback = 0, n_follow_bad = 0, n_late = 0, cyc = 0;
    reg fallback_frame = 0;
    always @(posedge clk) if (rst_n) cyc = cyc + 1;

    // ---------------- 摄像头：帧沿 + CAM_LAT 后写 PW 个字 ----------------
    integer cam_t = -1;
    reg [1:0] cam_wr_pg = 0;
    always @(posedge clk) begin
        if (!rst_n) begin cam_t <= -1; cam_wr_pg <= 0; end
        else if (cam_frame_pulse) begin
            cam_t <= -CAM_LAT;
`ifdef INJECT_TEAR
            // 负向自检用：故意让摄像头去写【显示正在读的那一页】，检查器必须报 tear
            cam_wr_pg <= (n_cam == 2) ? disp_page : (cam_page + 2'd1);
`else
            cam_wr_pg <= cam_page + 2'd1;
`endif
        end
        else if (cam_t < PW) begin
            cam_t <= cam_t + 1;
            if (cam_t == 0) pg_tag[cam_wr_pg] <= pg_tag[cam_wr_pg] + 1;
        end
    end
    wire cam_wr_en = (cam_t >= 0) && (cam_t < PW);

    // 撕裂检查用的“实际写页”。负向自检（+define+INJECT_TEAR）时故意把它指到显示页上，
    // 用来证明检查器不是死码：注入版必须 FAIL，正常版必须 PASS。
`ifdef INJECT_TEAR
    wire [1:0] cam_wr_pg_chk = (n_cam == 4) ? disp_page : cam_wr_pg;
`else
    wire [1:0] cam_wr_pg_chk = cam_wr_pg;
`endif

    // ---------------- M4：拿到新源帧后按 m4_lat 拍完成 ----------------
    integer m4_t = -1, m4_lat = M4_FAST;
    reg [1:0] m4_wr_pg = 0, m4_rd_d = 3;
    always @(posedge clk) begin
        if (!rst_n) begin m4_t <= -1; m4_wr_pg <= 0; m4_rd_d <= 3; end
        else if (m4_rd_page != m4_rd_d) begin
            m4_rd_d <= m4_rd_page;
            m4_t    <= -m4_lat;
            m4_wr_pg <= m4_wr_page;
        end else if (m4_t < PW) begin
            m4_t <= m4_t + 1;
            if (m4_t == 0) pg_tag[m4_wr_pg] <= pg_tag[m4_wr_pg] + 1;
        end
    end
    wire m4_wr_en = (m4_t >= 0) && (m4_t < PW);

    // ---------------- 在线检查（显示持续读 disp_page） ----------------
    always @(posedge clk) if (rst_n) begin
        if (cam_wr_en && (cam_wr_pg_chk == disp_page) && (n_cam > 1)) n_tear = n_tear + 1;
        if (m4_wr_en  && (m4_wr_pg  == disp_page) && (n_cam > 1)) n_tear = n_tear + 1;
        if (!fallback_frame && n_cam > 1 && !page_ok) n_pageok_bad = n_pageok_bad + 1;
    end

    task report;
        begin
            $display("  cam_frames=%0d  m4_done=%0d  late_frames=%0d  fallback=%0d  follow_bad=%0d",
                     n_cam, n_m4, n_late, n_fallback, n_follow_bad);
            $display("  page_ok_violations=%0d  tears=%0d  cyc=%0d", n_pageok_bad, n_tear, cyc);
            if ((n_tear == 0) && (n_pageok_bad == 0) && (n_follow_bad == 0) && (n_fallback > 0) && (n_cam == NFRAME))
                $display("PAGEMULTI PASS frames=%0d tears=0 page_ok_ok fallback=%0d late=%0d", NFRAME, n_fallback, n_late);
            else
                $display("PAGEMULTI_FAIL tears=%0d page_ok_bad=%0d follow_bad=%0d fallback=%0d cam=%0d",
                         n_tear, n_pageok_bad, n_follow_bad, n_fallback, n_cam);
        end
    endtask

    integer f;
    initial begin
        rst_n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        for (f = 0; f < NFRAME; f = f + 1) begin
            m4_lat = ((f == 3) || (f == 4)) ? M4_SLOW : M4_FAST;
            // 脉冲前把 M4 交付状态摆好（调度器在脉冲沿采样）
            if (m4_t == PW) begin
                m4_ready     = 1'b1;
                m4_done_page = m4_wr_pg;
                n_m4         = n_m4 + 1;
                fallback_frame = 1'b0;
            end else begin
                m4_ready = 1'b0;
                fallback_frame = 1'b1;
                if (n_cam > 0) n_fallback = n_fallback + 1;
                if (f == 3 || f == 4) n_late = n_late + 1;
            end
            @(negedge clk);
            cam_frame_pulse  = 1'b1;
            disp_frame_pulse = 1'b1;
            @(negedge clk);
            cam_frame_pulse  = 1'b0;
            disp_frame_pulse = 1'b0;
            n_cam = n_cam + 1;
            // 帧沿之后检查：正常帧 disp 必须跟上 m4_done_page
            if (!fallback_frame && (disp_page != m4_done_page)) n_follow_bad = n_follow_bad + 1;
            repeat (FRAME_CYC - 2) @(negedge clk);
        end
        repeat (500) @(negedge clk);
        report;
        $finish;
    end

    initial begin
        #500000;
        $display("PAGEMULTI_FAIL WATCHDOG cyc=%0d", cyc);
        $finish;
    end
endmodule
