`timescale 1ns/1ps
module tb_practice_tianzhen_excerpt;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,byte_valid=0,event_valid=0,sweep_valid=0;
    reg [31:0] byte_offset=0,event_tick=0,sweep_tick=0;
    reg [7:0] byte_data=0;
    reg [6:0] event_pitch=0;
    wire note_valid,descriptor_valid,score_onset;
    wire [31:0] note_index,start_tick,duration_tick,total_notes;
    wire [6:0] pitch;
    wire [1:0] part_mask;
    wire [15:0] default_bpm;
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
    practice_onset_match scorer(
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
    always @(posedge clk) if(note_valid && note_index<20) begin
        seen=seen+1;
        if(score_onset) scored=scored+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        fd=$fopen("sim/tianzhen-fixture.pseq","rb");
        if(fd==0) $fatal(1,"missing real Tianzhen PSC2 fixture");
        for(n=0;n<1530;n=n+1) begin
            c=$fgetc(fd);
            if(c<0) $fatal(1,"truncated fixture at %0d",n);
            byte_valid=1;byte_offset=n;byte_data=c[7:0];
            @(negedge clk);
        end
        byte_valid=0;
        $fclose(fd);
        repeat(3) @(negedge clk);
        if(!descriptor_valid || default_bpm!=112 || seen!=20 || scored!=20)
            $fatal(1,"descriptor=%b bpm=%0d seen=%0d scored=%0d",
                descriptor_valid,default_bpm,seen,scored);
        // NOTE id 2 is middle C (MIDI 60) at the start of the real excerpt.
        wait(ready);
        event_valid=1;event_tick=7169;event_pitch=60;
        @(negedge clk);event_valid=0;
        wait(hit_valid);
        if(hit_kind!=3 || hit_index!=2)
            $fatal(1,"real NOTE 2 score=%0d/%0d",hit_kind,hit_index);
        $display("PASS Tianzhen F5 excerpt: %0d scored targets, MIDI60 Perfect",
            scored);
        $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule
