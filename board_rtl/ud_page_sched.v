// ud_page_sched.v -- 4 页轮转调度（stage 2：摄像头 -> M4 -> 显示）
//
// 为什么需要：fram_buf 现在是【3 页】轮转（wr_buf 写 page 0->1->2，rd_buf 读"写页-1"）。
// 而 stage 2 一帧之内同时有四个角色要独占一页：
//   1 摄像头正在写 raw   2 M4 正在读 raw   3 M4 正在写纠正结果   4 显示正在读纠正结果
// 四者两两不能同页 => 至少 4 页。3 页必然冲突，这正是交接包 §3 那两个纠结的根源。
//
// 本模块只分配页号，不碰任何存储。一页 = 4 MB，页号在地址 [27:22]。
//
// 分配规则（每帧）：
//   cam_page   摄像头写：每个写帧沿 +1
//   m4_rd_page M4 读：= 摄像头【刚写完】的那一页
//   m4_wr_page M4 写：= cam / M4读 / 显示 三者之外的第四页（在帧沿锁存，整帧不变）
//   disp_page  显示读：在显示帧头【快照】到 M4 刚交出的那一页
//
// 为什么显示要"快照"而不是"+1"：M4 一旦漏帧，显示用 +1 就永远追不回来；
// 快照则漏几帧都能自己追上，而且保证只读 M4 已经交出的完整帧。
`timescale 1ns/1ps

module ud_page_sched (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cam_frame_pulse,   // 摄像头写完一帧（写侧 VSYNC 沿，1 拍脉冲）
    input  wire        m4_ready,          // M4 已有一帧纠正结果待显示
    input  wire [1:0]  m4_done_page,      // 那一帧在哪一页
    input  wire        disp_frame_pulse,  // 显示帧头

    output reg  [1:0]  cam_page,          // 摄像头本帧写哪页（raw）
    output reg  [1:0]  m4_rd_page,        // M4 本帧读哪页（源 raw）
    output reg  [1:0]  m4_wr_page,        // M4 本帧写哪页（纠正结果）
    output reg  [1:0]  disp_page,         // 显示本帧读哪页
    output reg         disp_page_valid,   // 0 = 上电头几帧还没有可显示内容
    output wire        page_ok            // 1 = 四路页号互不相同（自检）
);
    // ---- 摄像头页：每个写帧沿 +1 ----
    always @(posedge clk) begin
        if (!rst_n)               cam_page <= 2'd0;
        else if (cam_frame_pulse) cam_page <= cam_page + 2'd1;
    end

    // ---- M4 读页：= 刚写完的那一页（帧沿上的旧 cam_page）----
    always @(posedge clk) begin
        if (!rst_n)               m4_rd_page <= 2'd3;
        else if (cam_frame_pulse) m4_rd_page <= cam_page;
    end

    // ---- M4 写页：三者之外的第四页，帧沿锁存 ----
    // 帧沿上各角色的新页：cam_nxt = cam_page+1，M4 读 = cam_page，
    // 显示 = 旧的 m4_wr_page（M4 这一帧刚写完、正要交给显示的那页）。
    // 所以排除集必须用【旧 m4_wr_page】而不是 disp_page —— 两者在同一拍有竞争：
    // 显示帧头和摄像头帧沿是同一个边界，disp_page 这一拍还没更新。
    wire [1:0] cam_nxt = cam_page + 2'd1;
    reg  [1:0] free_pg;
    integer    i;
    always @(*) begin
        free_pg = 2'd0;
        for (i = 3; i >= 0; i = i - 1) begin
            if (i[1:0] != cam_nxt && i[1:0] != cam_page && i[1:0] != m4_wr_page)
                free_pg = i[1:0];
        end
    end
    always @(posedge clk) begin
        if (!rst_n)               m4_wr_page <= 2'd2;
        else if (cam_frame_pulse) m4_wr_page <= free_pg;
    end

    // ---- 显示页：在【摄像头帧沿】上换成 M4 刚交出的那一页 ----
    // 为什么要挂在摄像头帧沿、而不是显示帧头：两个 VSYNC 相位自由，
    // 若显示在"自己的帧头"换页，就会出现"摄像头已经开始写 P、显示还停在 P"的窗口
    // —— 这一段读到的是正在被覆盖的页（真损坏）。挂在写沿上，cam 与 disp 永远同拍 +1、
    // 偏移恒为 1，任何相位下都不会撞页。代价：换页点落在显示帧内部，有【一行】拼接
    // （原 3 页设计也是这个代价，见 rd_buf.v 的 [A-1] 注释）。
    // [M4-P4b] graceful degradation: if M4 has not delivered a frame yet, show the
    // camera page that was just written (raw but COMPLETE) instead of freezing a
    // stale page that the camera later overwrites (that was the blocky tearing).
    always @(posedge clk) begin
        if (!rst_n) begin
            disp_page       <= 2'd3;
            disp_page_valid <= 1'b0;
        end else if (cam_frame_pulse) begin
            if (m4_ready) begin
                disp_page       <= m4_done_page;
                disp_page_valid <= 1'b1;
            end else begin
                disp_page       <= cam_page;
            end
        end
    end

    // ---- 自检：四路互不相同 ----
    assign page_ok = (cam_page   != m4_rd_page) && (cam_page   != m4_wr_page) &&
                     (cam_page   != disp_page ) && (m4_rd_page != m4_wr_page) &&
                     (m4_rd_page != disp_page ) && (m4_wr_page != disp_page );
endmodule
