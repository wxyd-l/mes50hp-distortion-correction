`timescale 1ns/1ps
// Single registered read port, single configuration write port. Two frame banks.
// Config: begin -> sequential addresses 0..NODES-1 -> commit -> frame_start.
// All ports are on clk; any UART/CPU/DDR clock crossing belongs in an adapter.
module map_lut #(
    parameter NODES=984,
    parameter INIT_FILE=""
)(
    input wire clk, rst_n,
    input wire rd_en,
    input wire [15:0] rd_addr,
    output reg [63:0] rd_data,
    input wire cfg_begin, cfg_we, cfg_commit,
    input wire [15:0] cfg_addr,
    input wire [63:0] cfg_data,
    output wire cfg_ready,
    output reg cfg_error,
    input wire frame_start,
    output reg active_bank,
    output reg active_ready,
    output reg pending
);
    reg [63:0] memory [0:2*NODES-1];
    reg loading;
    reg [16:0] load_count;
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE,memory,0,NODES-1);
    end
    assign cfg_ready = loading && !pending && load_count < NODES;
    always @(posedge clk) begin
        if (rd_en) rd_data <= memory[(active_bank ? NODES : 0) + rd_addr];
        if (!rst_n) begin
            active_bank <= 0;
            // A soft reset cannot reinitialize RAM. Never mark a possibly
            // half-overwritten bank valid merely because INIT_FILE exists.
            active_ready <= 0;
            pending <= 0; loading <= 0; load_count <= 0; cfg_error <= 0;
        end else begin
            // Do not start a new load on the same cycle that the old bank flips.
            if (frame_start && pending) begin
                active_bank <= !active_bank;
                active_ready <= 1;
                pending <= 0;
            end
            if (cfg_begin) begin
                if (pending || cfg_we || cfg_commit || frame_start) begin
                    cfg_error <= 1;
                end else begin
                    loading <= 1; load_count <= 0; cfg_error <= 0;
                end
            end else if (cfg_we) begin
                if (cfg_ready && cfg_addr == load_count && !cfg_commit && !frame_start) begin
                    memory[(active_bank ? 0 : NODES)+cfg_addr] <= cfg_data;
                    load_count <= load_count + 1;
                end else begin
                    cfg_error <= 1; loading <= 0;
                end
            end else if (cfg_commit) begin
                if (loading && load_count == NODES && !cfg_error && !frame_start) begin
                    pending <= 1; loading <= 0;
                end else begin
                    cfg_error <= 1;
                end
            end
        end
    end
endmodule
