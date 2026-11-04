// ud_gamma565.v -- RGB565 三通道自适应 Gamma（7 档曲线 + 帧首换档 + 限步）
//
// 位置：采集侧，cmos_8_16bit 之后、fram_buf 写之前。题目要求 Gamma 必须在双线性之前
//       （非线性变换与插值不可交换），放这里正好不碰 M4 读核那条已经验证过的通路。
//
// 结构：
//   * 三张表各 7 档：R 5 位索引（7x32）、G 6 位（7x64）、B 5 位（7x32），表项 8 位；
//   * 统计的是【进 Gamma 之前】的原始像素（Y = (77R+150G+29B)>>8 累加 + 计数）；
//   * 帧首脉冲那拍：用上一帧的均值定下一档，并且【每帧最多动一档】（限步）；
//   * GAMMA_EN=0 时逐位直通、零延迟（保证旁路与未加 Gamma 的 bitstream 完全一致）。
//
// 延迟：GAMMA_EN=1 时 1 拍（表读出打一拍）。de_o 同步延迟，wr_en 直接接 de_o。
`timescale 1ns/1ps

module ud_gamma565 #(
    parameter integer GAMMA_EN = 1,
    parameter integer CNT_MIN  = 800000,      // 一帧像素数下限（低于它不换档，防坏帧）
    parameter integer HOLD_N   = 3,           // 滞回：候选档连续 N 帧一致才真的换档
    parameter integer AVG_SHIFT = 20,         // sum >> SHIFT = 平均亮度（921600 像素满幅白 -> 252）
    parameter [8*48-1:0] LUT_R_FILE = "gamma_r.hex",
    parameter [8*48-1:0] LUT_G_FILE = "gamma_g.hex",
    parameter [8*48-1:0] LUT_B_FILE = "gamma_b.hex"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,   // 帧首 1 拍脉冲（VSYNC 沿，任意极性）
    input  wire        de,
    input  wire [15:0] pix_i,
    output wire        de_o,
    output wire [15:0] pix_o,
    output reg  [2:0]  bank_o         // 当前档（观察用）
);
    reg [7:0] lut_r [0:7*32-1];
    reg [7:0] lut_g [0:7*64-1];
    reg [7:0] lut_b [0:7*32-1];
    initial begin
        $readmemh(LUT_R_FILE, lut_r);
        $readmemh(LUT_G_FILE, lut_g);
        $readmemh(LUT_B_FILE, lut_b);
    end

    wire [4:0] ri = pix_i[15:11];
    wire [5:0] gi = pix_i[10:5];
    wire [4:0] bi = pix_i[4:0];

    // ---- 亮度统计（原始像素）----
    wire [7:0]  r8 = {ri, 3'b000};
    wire [7:0]  g8 = {gi, 2'b00};
    wire [7:0]  b8 = {bi, 3'b000};
    wire [15:0] ysum = {8'd0, r8} * 16'd77 + {8'd0, g8} * 16'd150 + {8'd0, b8} * 16'd29;
    reg  [39:0] sum_y;
    reg  [31:0] cnt;

    // ---- 档位选择：均值 -> 目标档，再限步 ----
    wire [19:0] avg = sum_y >> AVG_SHIFT;      // 921600 像素满幅白时 ≈ 252
    reg  [2:0]  target;
    always @(*) begin
        if      (avg < 20'd40)  target = 3'd0;
        else if (avg < 20'd60)  target = 3'd1;
        else if (avg < 20'd85)  target = 3'd2;
        else if (avg < 20'd120) target = 3'd3;
        else if (avg < 20'd150) target = 3'd4;
        else if (avg < 20'd180) target = 3'd5;
        else                    target = 3'd6;
    end

    reg [2:0] bank;
    reg [2:0] cand;          // 候选档
    reg [1:0] stable_cnt;    // 候选已经稳定了几帧（HOLD_N <= 4）
    wire cnt_ok = (cnt >= CNT_MIN);
    // 每帧最多动一档（限步）
    wire [2:0] step_to = (target > bank) ? (bank + 3'd1) : (bank - 3'd1);
    // [A3-hyst] 只靠限步不够：场景均值卡在阈值上时 target 会逐帧变，画面会闪。
    // 这里要求【候选档连续 HOLD_N 帧都是同一个 target】才真的换档 —— 阈值附近的抖动
    // 会让 stable_cnt 反复清零，档位不动；真实光照变化会持续 N 帧，正常跟上。

    always @(posedge clk) begin
        if (!rst_n) begin
            sum_y <= 40'd0; cnt <= 32'd0; bank <= 3'd3; cand <= 3'd3; stable_cnt <= 2'd0;
        end else if (frame_start) begin
            sum_y <= 40'd0;
            cnt   <= 32'd0;
            // 用上一帧的统计定这一帧的档，带滞回 + 限步
            if (!cnt_ok) begin
                cand <= target;  stable_cnt <= 2'd0;          // 坏帧/帧数不足：不动档
            end else if (target == bank) begin
                cand <= target;  stable_cnt <= 2'd0;
            end else if (target == cand) begin
                if (stable_cnt == HOLD_N - 1) begin
                    bank <= step_to;  stable_cnt <= 2'd0;     // 连续 N 帧一致 -> 动一档
                end else stable_cnt <= stable_cnt + 2'd1;
            end else begin
                cand <= target;  stable_cnt <= 2'd0;          // 候选变了：重新计数
            end
        end else if (de) begin
            sum_y <= sum_y + {32'd0, ysum[15:8]};
            cnt   <= cnt + 32'd1;
        end
    end

    // ---- 查表（1 拍）----
    reg [7:0] qr, qg, qb;
    reg       de_d1;
    always @(posedge clk) begin
        qr    <= lut_r[{bank, ri}];
        qg    <= lut_g[{bank, gi}];
        qb    <= lut_b[{bank, bi}];
        de_d1 <= de;
    end
    wire [15:0] pix_g = {qr[7:3], qg[7:2], qb[7:3]};

    assign pix_o = (GAMMA_EN != 0) ? pix_g : pix_i;
    assign de_o  = (GAMMA_EN != 0) ? de_d1 : de;

    always @(posedge clk) bank_o <= bank;
endmodule
