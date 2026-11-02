`timescale 1ns/1ps
// Issue two identical piano-partial jobs per clock. Each lane owns 16 note
// slots and visits all 32 partials for every slot once per audio frame.
// This module is only the scheduler; it must not be used as an audio engine.
module poly32_partial_scheduler #(
    parameter integer PIPELINE_DRAIN = 8
) (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    output reg job_valid,
    output reg [4:0] voice0,
    output reg [4:0] voice1,
    output reg [5:0] partial,
    output reg frame_done,
    output reg overrun
);
    reg [8:0] issue_index;
    reg issuing;
    reg [7:0] drain_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_index <= 0;
            issuing <= 0;
            drain_count <= 0;
            job_valid <= 0;
            voice0 <= 0;
            voice1 <= 16;
            partial <= 1;
            frame_done <= 0;
            overrun <= 0;
        end else begin
            job_valid <= 0;
            frame_done <= 0;
            if (sample_tick) begin
                if (issuing || drain_count != 0)
                    overrun <= 1;
                else begin
                    issue_index <= 0;
                    issuing <= 1;
                end
            end else if (issuing) begin
                job_valid <= 1;
                voice0 <= {1'b0, issue_index[8:5]};
                voice1 <= {1'b1, issue_index[8:5]};
                partial <= {1'b0, issue_index[4:0]} + 6'd1;
                if (issue_index == 9'd511) begin
                    issuing <= 0;
                    drain_count <= PIPELINE_DRAIN;
                end else begin
                    issue_index <= issue_index + 1'b1;
                end
            end else if (drain_count != 0) begin
                drain_count <= drain_count - 1'b1;
                if (drain_count == 1)
                    frame_done <= 1;
            end
        end
    end
endmodule
