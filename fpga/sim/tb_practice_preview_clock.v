`timescale 1ns/1ps
// Small-clock equivalent of the sys-clock preview/score integration.
module tb_practice_preview_clock;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,active=0,paused=0;
    wire [31:0] tick;
    wire [11:0] scroll;
    score_demo_clock #(.CLOCK_HZ(8000),.LEAD_IN_TICKS(7168)) clock_dut(
        .pixel_clk(clk),.rst_n(rst_n),.active(active),.paused(paused),
        .bpm(16'd100),.loop_ticks(32'd960),
        .current_tick(tick),.current_scroll_px(scroll)
    );
    wire [31:0] stop_tick;
    score_demo_clock #(.CLOCK_HZ(8000),.LEAD_IN_TICKS(0),
        .STOP_AT_END(1)) stopped_clock(
        .pixel_clk(clk),.rst_n(rst_n),.active(active),.paused(paused),
        .bpm(16'd100),.loop_ticks(32'd960),
        .current_tick(stop_tick),.current_scroll_px()
    );
    reg target_valid=0,event_valid=0;
    reg [31:0] event_tick=0;
    wire ready,hit_valid,miss_valid;
    wire [2:0] hit_kind;
    wire [4:0] hit_index,miss_index;
    reg [31:0] previous_tick=0;
    reg [31:0] paused_tick;
    always @(posedge clk) previous_tick<=tick;
    practice_onset_match scorer(
        .clk(clk),.rst_n(rst_n),.clear(1'b0),.restart(1'b0),
        .target_valid(target_valid),.target_index(5'd0),
        .target_tick(32'd7169),.target_pitch(7'd60),
        .target_part(2'd2),.target_score_onset(1'b1),
        .selected_parts(2'd3),.bpm(16'd100),
        .event_valid(event_valid),.event_tick(event_tick),
        .event_pitch(7'd60),.event_ready(ready),
        .hit_valid(hit_valid),.hit_kind(hit_kind),.hit_index(hit_index),
        .sweep_valid(tick!=previous_tick),.sweep_tick(tick),
        .miss_valid(miss_valid),.miss_index(miss_index)
    );
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        target_valid=1;
        @(negedge clk);target_valid=0;active=1;
        wait(tick==32'd7169);
        if(scroll!==12'd360)
            $fatal(1,"key line scroll=%0d expected 360",scroll);
        wait(ready);
        @(negedge clk);event_tick=tick;event_valid=1;
        @(negedge clk);event_valid=0;
        wait(hit_valid);
        if(hit_kind!==3'd3 || hit_index!==0)
            $fatal(1,"expected Perfect at lead-in, got %0d/%0d",
                hit_kind,hit_index);
        paused=1;
        paused_tick=tick;
        repeat(20) @(negedge clk);
        if(tick!==paused_tick)
            $fatal(1,"clock advanced while paused: %0d -> %0d",
                paused_tick,tick);
        // The final scored onset may have a short duration. Do not restart
        // before its +100 ms Good window and Miss sweep have both elapsed.
        paused=0;
        wait(tick==32'd8128);
        if(tick<32'd8128)
            $fatal(1,"preview loop restarted before final scoring window");
        @(negedge clk);
        if(tick<32'd8128)
            $fatal(1,"preview loop restarted at final note end");
        wait(tick==32'd8210);
        if(tick<32'd8210)
            $fatal(1,"preview loop restarted before +100 ms tail");
        if(stop_tick!=32'd1061)
            $fatal(1,"stopped practice clock wrapped at %0d",stop_tick);
        wait(tick==0);
        if(scroll!=0)
            $fatal(1,"preview scroll did not return for 20-note replay");
        $display("PASS practice preview clock: tick=%0d scroll=%0d",tick,scroll);
        $finish;
    end
    initial begin #2000000; $fatal(1,"timeout"); end
endmodule
