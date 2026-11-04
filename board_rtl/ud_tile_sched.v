// =============================================================================
//  ud_tile_sched.v -- 8 列条轮转调度器
// =============================================================================
`timescale 1ns/1ps
module ud_tile_sched #(
    parameter integer TW     = 160,
    parameter integer HEIGHT = 720,
    parameter integer NT     = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        tile_done,
    output reg         start,
    output reg  [11:0] row_v,
    output reg  [11:0] tile_x0,
    output reg  [3:0]  tile_idx,
    output reg         frame_done
);
    localparam S_IDLE = 0, S_ISSUE = 1, S_WAIT = 2;

    reg [1:0]  st;
    reg [11:0] r;
    reg [3:0]  t;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; start <= 1'b0; row_v <= 0; tile_x0 <= 0;
            tile_idx <= 0; frame_done <= 1'b0; r <= 0; t <= 0;
        end else begin
            start <= 1'b0; frame_done <= 1'b0;
            case (st)
            S_IDLE: if (frame_start) begin r <= 0; t <= 0; st <= S_ISSUE; end
            S_ISSUE: begin
                start    <= 1'b1;
                row_v    <= r;
                tile_x0  <= t * TW;
                tile_idx <= t;
                st       <= S_WAIT;
            end
            S_WAIT: begin
                if (tile_done) begin
                    if (r == HEIGHT-1) begin
                        r <= 0;
                        if (t == NT-1) begin t <= 0; st <= S_IDLE; frame_done <= 1'b1; end
                        else begin t <= t + 1'b1; st <= S_ISSUE; end
                    end else begin
                        r <= r + 1'b1; st <= S_ISSUE;
                    end
                end
            end
            endcase
        end
    end
endmodule
