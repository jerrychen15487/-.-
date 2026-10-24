`timescale 1ns/1ps
// Match MIDI Note On events to loaded PSC2 NOTE targets. A registered memory
// read separates target lookup from comparison for the full-song bank.
// Time uses the existing 8*BPM/second preview clock and common lead-in;
// this is onset scoring, not the full four-component F5 scorer.
module practice_onset_match #(
    parameter integer TARGETS = 20,
    parameter integer INDEX_BITS = 5
) (
    input wire clk, rst_n, clear, restart,
    input wire target_valid,
    input wire [INDEX_BITS-1:0] target_index,
    input wire [31:0] target_tick,
    input wire [6:0] target_pitch,
    input wire [1:0] target_part,
    input wire target_score_onset,
    input wire [1:0] selected_parts,
    input wire [15:0] bpm,
    input wire event_valid,
    input wire [31:0] event_tick,
    input wire [6:0] event_pitch,
    output wire event_ready,
    // kind: 0 extra wrong note, 1 unscored reference, 2 Good,
    // 3 Perfect, 4 correct note in an unselected part.
    output reg hit_valid,
    output reg [2:0] hit_kind,
    output reg [INDEX_BITS-1:0] hit_index,
    input wire sweep_valid,
    input wire [31:0] sweep_tick,
    output reg miss_valid,
    output reg [INDEX_BITS-1:0] miss_index
);
    localparam IDLE=3'd0, SCAN_READ=3'd1, SCAN=3'd2,
        RESOLVE=3'd3, SWEEP_READ=3'd4, SWEEP=3'd5;
    reg [2:0] state;
    // The NOTE stream arrives in ascending index order. Presence is encoded
    // by loaded_count, and the score bit lives beside the target in BSRAM.
    // Only consumed state needs random updates during a practice run.
    reg [41:0] targets [0:TARGETS-1];
    reg [41:0] target_q;
    reg [INDEX_BITS:0] loaded_count;
    reg [TARGETS-1:0] consumed;
    reg [INDEX_BITS-1:0] scan_index;
    reg [31:0] held_tick, held_sweep_tick;
    reg [15:0] held_bpm;
    reg [6:0] held_pitch;
    reg [1:0] held_parts;
    reg best_selected, best_other, selected_perfect, selected_scored;
    reg [31:0] selected_diff, other_diff;
    reg [INDEX_BITS-1:0] selected_index, other_index;
    wire [31:0] target_time=target_q[41:10];
    wire [6:0] target_pitch_q=target_q[9:3];
    wire [1:0] target_part_q=target_q[2:1];
    wire target_scored_q=target_q[0];
    wire [31:0] distance=held_tick>=target_time ?
        held_tick-target_time : target_time-held_tick;
    wire [10:0] distance_x5={1'b0,distance[7:0],2'b0}+
                           {3'b0,distance[7:0]};
    // At 8*BPM ticks/s, 50/100 ms equal 0.4/0.8*BPM ticks.
    wire within_good=distance[31:8]==0 &&
        distance_x5<={held_bpm,2'b0};
    wire within_perfect=distance[31:8]==0 &&
        distance_x5<={held_bpm,1'b0};
    wire [31:0] sweep_age=held_sweep_tick-target_time;
    wire [10:0] sweep_age_x5={1'b0,sweep_age[7:0],2'b0}+
                            {3'b0,sweep_age[7:0]};
    wire past_good_window=held_sweep_tick>target_time &&
        (sweep_age[31:8]!=0 || sweep_age_x5>{held_bpm,2'b0});
    wire candidate=({1'b0,scan_index}<loaded_count) &&
        !consumed[scan_index] &&
        target_pitch_q==held_pitch && within_good;
    assign event_ready=(state==IDLE) && !clear && !target_valid;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; loaded_count<=0; consumed<=0;
            scan_index<=0; target_q<=0; held_tick<=0; held_sweep_tick<=0;
            held_bpm<=0;
            held_pitch<=0; held_parts<=0;
            best_selected<=0; best_other<=0;
            selected_perfect<=0; selected_scored<=0;
            selected_diff<=0; other_diff<=0;
            selected_index<=0; other_index<=0;
            hit_valid<=0; hit_kind<=0; hit_index<=0;
            miss_valid<=0; miss_index<=0;
        end else begin
            hit_valid<=0;
            miss_valid<=0;
            if(clear) begin
                state<=IDLE; loaded_count<=0; consumed<=0;
            end else if(restart) begin
                state<=IDLE; consumed<=0;
            end else case(state)
                IDLE:begin
                    if(target_valid && target_index<TARGETS) begin
                        targets[target_index]<={target_tick,target_pitch,
                            target_part,target_score_onset};
                        if({1'b0,target_index}==loaded_count)
                            loaded_count<=loaded_count+1'b1;
                        consumed[target_index]<=1'b0;
                    end else if(event_valid) begin
                        held_tick<=event_tick;
                        held_pitch<=event_pitch;
                        held_parts<=selected_parts;
                        held_bpm<=bpm;
                        scan_index<=0;
                        best_selected<=0; best_other<=0;
                        selected_perfect<=0; selected_scored<=0;
                        state<=SCAN_READ;
                    end else if(sweep_valid) begin
                        held_sweep_tick<=sweep_tick;
                        held_parts<=selected_parts;
                        held_bpm<=bpm;
                        scan_index<=0;
                        state<=SWEEP_READ;
                    end
                end
                SCAN_READ:begin
                    target_q<=targets[scan_index];
                    state<=SCAN;
                end
                SCAN:begin
                    if(candidate) begin
                        if((target_part_q & held_parts)!=0) begin
                            if(!best_selected || distance<selected_diff) begin
                                best_selected<=1;
                                selected_diff<=distance;
                                selected_index<=scan_index;
                                selected_perfect<=within_perfect;
                                selected_scored<=target_scored_q;
                            end
                        end else if(!best_other || distance<other_diff) begin
                            best_other<=1;
                            other_diff<=distance;
                            other_index<=scan_index;
                        end
                    end
                    if(scan_index==TARGETS-1) state<=RESOLVE;
                    else begin
                        scan_index<=scan_index+1'b1;
                        state<=SCAN_READ;
                    end
                end
                RESOLVE:begin
                    hit_valid<=1;
                    if(best_selected) begin
                        consumed[selected_index]<=1;
                        hit_index<=selected_index;
                        if(!selected_scored) hit_kind<=3'd1;
                        else if(selected_perfect) hit_kind<=3'd3;
                        else hit_kind<=3'd2;
                    end else if(best_other) begin
                        consumed[other_index]<=1;
                        hit_index<=other_index;
                        hit_kind<=3'd4;
                    end else begin
                        hit_index<=0;
                        hit_kind<=3'd0;
                    end
                    state<=IDLE;
                end
                SWEEP_READ:begin
                    target_q<=targets[scan_index];
                    state<=SWEEP;
                end
                SWEEP:begin
                    if({1'b0,scan_index}<loaded_count &&
                       !consumed[scan_index] && target_scored_q &&
                       (target_part_q & held_parts)!=0 &&
                       past_good_window) begin
                        consumed[scan_index]<=1;
                        miss_valid<=1;
                        miss_index<=scan_index;
                    end
                    if(scan_index==TARGETS-1) state<=IDLE;
                    else begin
                        scan_index<=scan_index+1'b1;
                        state<=SWEEP_READ;
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
