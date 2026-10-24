`timescale 1ns/1ps
module tb_practice_tianzhen_full_onsets;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,byte_valid=0,event_valid=0,sweep_valid=0;
    reg read_done=0;
    reg [31:0] byte_offset=0,event_tick=0,sweep_tick=0;
    reg [7:0] byte_data=0;
    reg [6:0] event_pitch=0;
    wire note_valid,descriptor_valid,score_onset;
    wire [31:0] note_index,start_tick,duration_tick,total_notes;
    wire [6:0] pitch;
    wire [1:0] part_mask;
    wire [15:0] default_bpm;
    wire preview_loaded;
    wire [31:0] full_loop_ticks;
    piano_preview_cache preview(
        .clk(clk),.rst_n(rst_n),.clear(1'b0),
        .note_valid(note_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .pitch(pitch),.part_mask(part_mask),
        .read_done(read_done),.read_available(1'b1),
        .read_bpm(default_bpm),.loaded(preview_loaded),
        .loop_ticks(full_loop_ticks)
    );
    psc2_note_stream decoder(
        .clk(clk),.rst_n(rst_n),.byte_valid(byte_valid),
        .byte_offset(byte_offset),.byte_data(byte_data),
        .note_valid(note_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .pitch(pitch),.part_mask(part_mask),.score_onset(score_onset),
        .descriptor_valid(descriptor_valid),.total_notes(total_notes),
        .default_bpm(default_bpm)
    );
    wire ready,hit_valid,miss_valid;
    wire [2:0] hit_kind;
    wire [4:0] hit_index,miss_index;
    practice_onset_match #(.TARGETS(20),.INDEX_BITS(5)) scorer(
        .clk(clk),.rst_n(rst_n),.clear(1'b0),.restart(1'b0),
        .target_valid(note_valid && note_index<20),
        .target_index(note_index[4:0]),
        .target_tick(start_tick+32'd7169),
        .target_pitch(pitch),.target_part(part_mask),
        .target_score_onset(score_onset),
        .selected_parts(2'd3),.bpm(default_bpm),
        .event_valid(event_valid),.event_tick(event_tick),
        .event_pitch(event_pitch),.event_ready(ready),
        .hit_valid(hit_valid),.hit_kind(hit_kind),.hit_index(hit_index),
        .sweep_valid(sweep_valid),.sweep_tick(sweep_tick),
        .miss_valid(miss_valid),.miss_index(miss_index)
    );
    integer fd,n,c,seen=0,scored=0;
    always @(posedge clk) if(note_valid) begin
        seen=seen+1;
        if(score_onset) scored=scored+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        fd=$fopen("sim/tianzhen-fixture.pseq","rb");
        if(fd==0) $fatal(1,"missing Tianzhen fixture");
        for(n=0;n<759412;n=n+1) begin
            c=$fgetc(fd);
            if(c<0) $fatal(1,"truncated fixture at %0d",n);
            byte_valid=1;byte_offset=n;byte_data=c[7:0];
            @(negedge clk);
        end
        byte_valid=0;
        $fclose(fd);
        repeat(3) @(negedge clk);
        read_done=1;
        @(negedge clk);read_done=0;
        repeat(3) @(negedge clk);
        if(!descriptor_valid || total_notes!=414 || seen!=414 || scored!=414)
            $fatal(1,"bad full NOTE load: declared=%0d seen=%0d scored=%0d",
                total_notes,seen,scored);
        if(!preview_loaded || full_loop_ticks!=32'd3840)
            $fatal(1,"visible excerpt clock bound=%0d loaded=%b",
                full_loop_ticks,preview_loaded);
        // All 414 records are decoded, but only the 20 visible records may
        // enter the score matcher. An off-screen last note must not score.
        wait(ready);
        @(negedge clk);
        event_valid=1;event_tick=32'd97409;event_pitch=7'd65;
        @(negedge clk);event_valid=0;
        wait(hit_valid);
        if(hit_kind!=0)
            $fatal(1,"off-screen NOTE scored kind=%0d",hit_kind);
        wait(ready);
        @(negedge clk);
        event_valid=1;
        @(negedge clk);event_valid=0;
        wait(!hit_valid);
        wait(hit_valid);
        if(hit_kind!=0)
            $fatal(1,"off-screen NOTE scored on repeat kind=%0d",hit_kind);
        $display("PASS Tianzhen 414-note decode, 20-note visible score bound");
        $finish;
    end
    initial begin #20000000; $fatal(1,"timeout"); end
endmodule
