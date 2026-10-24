`timescale 1ns/1ps
// Running statistics for the limited 20-NOTE onset-practice trial.
// Unscored references and correctly played unselected parts never change
// score or combo. Counts saturate rather than wrap on long practice runs.
module practice_onset_stats (
    input wire clk, rst_n, clear, restart,
    input wire hit_valid,
    input wire [2:0] hit_kind,
    input wire miss_valid,
    output reg [6:0] combo,
    output reg [6:0] max_combo,
    output reg [6:0] perfect_count,
    output reg [6:0] good_count,
    output reg [6:0] miss_count,
    output reg [6:0] wrong_count
);
    wire scored_hit = hit_valid &&
        (hit_kind==3'd2 || hit_kind==3'd3);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            combo<=0;max_combo<=0;
            perfect_count<=0;good_count<=0;
            miss_count<=0;wrong_count<=0;
        end else if(clear || restart) begin
            combo<=0;max_combo<=0;
            perfect_count<=0;good_count<=0;
            miss_count<=0;wrong_count<=0;
        end else if(miss_valid) begin
            combo<=0;
            if(miss_count<7'd99) miss_count<=miss_count+1'b1;
        end else if(hit_valid) begin
            if(scored_hit) begin
                if(combo<7'd99) combo<=combo+1'b1;
                if(combo>=max_combo && max_combo<7'd99)
                    max_combo<=max_combo+1'b1;
                if(hit_kind==3'd3 && perfect_count<7'd99)
                    perfect_count<=perfect_count+1'b1;
                if(hit_kind==3'd2 && good_count<7'd99)
                    good_count<=good_count+1'b1;
            end else if(hit_kind==3'd0) begin
                combo<=0;
                if(wrong_count<7'd99) wrong_count<=wrong_count+1'b1;
            end
        end
    end
endmodule
