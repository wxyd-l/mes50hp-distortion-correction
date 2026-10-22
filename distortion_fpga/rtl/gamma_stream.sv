`timescale 1ns/1ps
// Raw RGB888 source stream -> enhanced source stream, before frame storage.
// Markers/configuration belong to accepted pixels. Each frame has SOF and EOF.
module gamma_stream #(
    parameter LUT_FILE = "rtl/gamma_lut.hex"
)(
    input wire clk, input wire rst_n,
    input wire [1:0] cfg_mode, // 0 bypass, 1 fixed, 2 adaptive (3 aliases bypass)
    input wire [2:0] cfg_bank, // 7 clamps to 6
    input wire in_valid, output wire in_ready,
    input wire [23:0] in_rgb, input wire in_sof, input wire in_eof,
    output reg out_valid, input wire out_ready,
    output reg [23:0] out_rgb, output reg out_sof, output reg out_eof,
    output reg [2:0] out_bank,
    output reg stats_valid, output reg [39:0] stats_sum,
    output reg [31:0] stats_count
);
    reg [7:0] lut [0:1791];
    initial $readmemh(LUT_FILE, lut);
    reg [1:0] frame_mode;
    reg [2:0] frame_bank, next_bank, target_bank;
    reg [39:0] sum_y;
    reg [31:0] count;
    wire [1:0] pixel_mode = in_sof ? cfg_mode : frame_mode;
    wire [2:0] fixed_bank = cfg_bank > 6 ? 3'd6 : cfg_bank;
    wire [2:0] start_bank = cfg_mode == 1 ? fixed_bank :
                           cfg_mode == 2 && frame_mode == 2 ? next_bank : 3'd3;
    wire [2:0] pixel_bank = in_sof ? start_bank : frame_bank;
    // Unsigned 16 bits hold the largest weighted sum, 255*256+128=65408.
    wire [15:0] r = {8'd0,in_rgb[23:16]};
    wire [15:0] g = {8'd0,in_rgb[15:8]};
    wire [15:0] b = {8'd0,in_rgb[7:0]};
    wire [15:0] weighted_y = (r<<6)+(r<<3)+(r<<2)+r
                          +(g<<7)+(g<<4)+(g<<2)+(g<<1)
                          +(b<<4)+(b<<3)+(b<<2)+b+16'd128;
    wire [39:0] end_sum = (in_sof ? 40'd0 : sum_y) + {32'd0, weighted_y[15:8]};
    wire [31:0] end_count = (in_sof ? 32'd0 : count) + 32'd1;
    wire [2:0] old_target = in_sof && frame_mode != 2 ? 3'd3 : target_bank;

    function automatic [39:0] boundary_sum(input [39:0] n, input [2:0] index);
        case (index)
            0: boundary_sum=n<<5;
            1: boundary_sum=n<<6;
            2: boundary_sum=(n<<6)+(n<<5);
            3: boundary_sum=(n<<7)+(n<<5);
            4: boundary_sum=(n<<7)+(n<<6);
            default: boundary_sum=(n<<7)+(n<<6)+(n<<5);
        endcase
    endfunction
    function automatic [2:0] choose_target(
        input [39:0] total, input [31:0] samples, input [2:0] previous
    );
        reg [39:0] n;
        reg hold_low, hold_high;
        integer j;
        begin
            n={8'd0,samples};
            hold_low = previous == 0 || total >= boundary_sum(n,previous-1'b1)-(n<<2);
            hold_high = previous == 6 || total < boundary_sum(n,previous)+(n<<2);
            choose_target=0;
            if (hold_low && hold_high) choose_target=previous;
            else for (j=0;j<6;j=j+1)
                if (total >= boundary_sum(n,j)) choose_target=j+1;
        end
    endfunction
    wire [2:0] new_target = choose_target(end_sum,end_count,old_target);
    assign in_ready = !out_valid || out_ready;
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid<=0; out_rgb<=0; out_sof<=0; out_eof<=0; out_bank<=3;
            frame_mode<=0; frame_bank<=3; next_bank<=3; target_bank<=3;
            sum_y<=0; count<=0; stats_valid<=0; stats_sum<=0; stats_count<=0;
        end else begin
            stats_valid<=0;
            if (in_ready) begin
                out_valid<=in_valid;
                if (in_valid) begin
                    out_rgb<={lut[{pixel_bank,in_rgb[23:16]}],
                              lut[{pixel_bank,in_rgb[15:8]}],lut[{pixel_bank,in_rgb[7:0]}]};
                    out_sof<=in_sof; out_eof<=in_eof; out_bank<=pixel_bank;
                    sum_y<=end_sum; count<=end_count;
                    if (in_sof) begin
                        frame_mode<=cfg_mode; frame_bank<=start_bank;
                        if (cfg_mode != 2 || frame_mode != 2) begin
                            next_bank<=3; target_bank<=3;
                        end
                    end
                    if (in_eof) begin
                        stats_valid<=1; stats_sum<=end_sum; stats_count<=end_count;
                        if (pixel_mode == 2) begin
                            target_bank<=new_target;
                            if (pixel_bank < new_target) next_bank<=pixel_bank+1'b1;
                            else if (pixel_bank > new_target) next_bank<=pixel_bank-1'b1;
                            else next_bank<=pixel_bank;
                        end
                    end
                end
            end
        end
    end
endmodule
