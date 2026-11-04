`timescale 1ns/1ps
module tb_cdc;
    reg clk_a = 0, clk_b = 0, rst_a_n = 0, rst_b_n = 0;
    always #11.9045 clk_a = ~clk_a;   // 42 MHz
    always #10.0    clk_b = ~clk_b;   // 50 MHz

    reg  pa = 0, pb = 0;
    wire pb_out, pa_out;

    ud_cdc_pulse u_ab (.clk_a(clk_a), .rst_a_n(rst_a_n), .pulse_a(pa),
                       .clk_b(clk_b), .rst_b_n(rst_b_n), .pulse_b(pb_out));
    ud_cdc_pulse u_ba (.clk_a(clk_b), .rst_a_n(rst_b_n), .pulse_a(pb),
                       .clk_b(clk_a), .rst_b_n(rst_a_n), .pulse_b(pa_out));

    integer i, n_ab, n_ba, sent;
    // 源域 A 每 3 拍打一个（最坏情形：连续单拍脉冲）
    reg run = 1;
    integer ca;
    reg fire_a;
    always @(posedge clk_a) begin
        if (!rst_a_n) begin ca <= 0; fire_a <= 0; end
        else begin
            ca <= ca + 1;
            fire_a <= 0;
            if (run && (ca % 3 == 0)) fire_a <= 1;
        end
    end
    always @(negedge clk_a) pa <= fire_a;

    integer cb;
    reg fire_b;
    always @(posedge clk_b) begin
        if (!rst_b_n) begin cb <= 0; fire_b <= 0; end
        else begin
            cb <= cb + 1;
            fire_b <= 0;
            if (run && (cb % 3 == 0)) fire_b <= 1;
        end
    end
    always @(negedge clk_b) pb <= fire_b;

    integer s_ab, s_ba;
    always @(posedge clk_a) if (rst_a_n && fire_a) s_ab <= s_ab + 1;
    always @(posedge clk_b) if (rst_b_n && fire_b) s_ba <= s_ba + 1;
    always @(posedge clk_b) if (rst_b_n && pb_out) n_ab <= n_ab + 1;
    always @(posedge clk_a) if (rst_a_n && pa_out) n_ba <= n_ba + 1;

    initial begin
        n_ab = 0; n_ba = 0; s_ab = 0; s_ba = 0;
        #100 rst_a_n = 1; rst_b_n = 1;
        #18000 run = 0;      // 停源，等同步器把最后一个搬完
        #1000;
        $display("CDC 42MHz->50MHz: 发 %0d 收 %0d %s", s_ab, n_ab, (s_ab == n_ab) ? "PASS" : "FAIL");
        $display("CDC 50MHz->42MHz: 发 %0d 收 %0d %s", s_ba, n_ba, (s_ba == n_ba) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
