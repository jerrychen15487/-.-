`timescale 1ns/1ps
module tb_practice_onset_match;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,clear=0,restart=0,target_valid=0,event_valid=0,sweep_valid=0;
    reg [4:0] target_index=0;
    reg [31:0] target_tick=0,event_tick=0,sweep_tick=0;
    reg [15:0] bpm=100;
    reg [6:0] target_pitch=0,event_pitch=0;
    reg [1:0] target_part=0,selected_parts=2;
    reg target_score_onset=0;
    wire event_ready,hit_valid,miss_valid;
    wire [2:0] hit_kind;
    wire [4:0] hit_index,miss_index;
    practice_onset_match dut(.*);
    integer hits=0,misses=0;
    reg [2:0] last_kind;
    reg [4:0] last_index,last_miss;
    always @(posedge clk) if(rst_n) begin
        if(hit_valid) begin
            hits=hits+1;
            last_kind=hit_kind;
            last_index=hit_index;
        end
        if(miss_valid) begin
            misses=misses+1;
            last_miss=miss_index;
        end
    end
    task add_target;
        input [4:0] idx;
        input [31:0] ms;
        input [6:0] p;
        input [1:0] part;
        input score;
        begin
            @(negedge clk);
            target_valid=1;target_index=idx;target_tick=ms;
            target_pitch=p;target_part=part;target_score_onset=score;
            @(negedge clk);target_valid=0;
        end
    endtask
    task play;
        input [31:0] ms;
        input [6:0] p;
        input [2:0] expected_kind;
        input [4:0] expected_index;
        integer before_hits;
        begin
            wait(event_ready);
            @(negedge clk);
            before_hits=hits;event_valid=1;event_tick=ms;event_pitch=p;
            @(negedge clk);event_valid=0;
            wait(hits>before_hits);
            if(last_kind!==expected_kind ||
               (expected_kind!=0 && last_index!==expected_index))
                $fatal(1,"hit kind=%0d index=%0d expected=%0d/%0d",
                    last_kind,last_index,expected_kind,expected_index);
        end
    endtask
    task sweep;
        input [31:0] ms;
        begin
            wait(event_ready);
            @(negedge clk);sweep_valid=1;sweep_tick=ms;
            @(negedge clk);sweep_valid=0;
            wait(event_ready);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        // Two repeated notes: nearest wins, then each can be consumed once.
        add_target(0,1000,60,2,1);
        add_target(1,1060,60,2,1);
        add_target(2,1000,64,1,1);
        add_target(3,1200,67,2,0);
        add_target(4,1400,69,2,1);
        play(960,60,3,0);  // 40 ticks at 100 BPM = -50 ms
        play(1100,60,3,1); // +50 ms
        play(1000,64,4,2); // unselected part: correct, no penalty
        play(1000,64,0,0); // consumed unselected reference cannot be reused
        play(1280,67,1,3); // unscored reference at +100 ms
        sweep(1480);       // target 4 still inside the window
        if(misses!=0) $fatal(1,"premature miss");
        sweep(1481);
        if(misses!=1 || last_miss!=4) $fatal(1,"miss boundary");
        play(1400,69,0,0); // missed target cannot be recovered
        // Clear permits deterministic fresh practice round.
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        add_target(0,2000,72,2,1);
        play(2080,72,2,0); // exactly +100 ms: Good
        play(2081,72,0,0);
        // Selected part wins even when an unselected target is nearer.
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        add_target(0,3000,60,1,1);
        add_target(1,3070,60,2,1);
        play(3010,60,2,1);
        play(3010,60,4,0);
        // Equal-distance selected candidates use lower note_id.
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        add_target(0,4000,60,2,1);
        add_target(1,4080,60,2,1);
        play(4040,60,3,0);
        play(4040,60,3,1);
        // An unscored target remains matchable but never becomes a Miss.
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        add_target(0,5000,60,2,0);
        sweep(5081);
        if(misses!=1) $fatal(1,"unscored target produced a miss");
        // A visual loop restart reuses loaded targets without an SD reread.
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        add_target(0,6000,72,2,1);
        play(6000,72,3,0);
        @(negedge clk);restart=1;
        @(negedge clk);restart=0;
        play(6000,72,3,0);
        $display("PASS practice_onset_match: %0d hits, %0d misses",hits,misses);
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
