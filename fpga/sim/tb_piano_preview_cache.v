`timescale 1ns/1ps
module tb_piano_preview_cache;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,clear=0,note_valid=0,read_done=0;
    reg [31:0] note_index=0,start_tick=0,duration_tick=0;
    reg [6:0] pitch=0;
    reg [1:0] part_mask=0;
    wire loaded;
    wire [15:0] bpm;
    wire [31:0] loop_ticks;
    wire [19:0] valid_mask;
    wire [239:0] start_px_bus,length_px_bus;
    wire [199:0] x_left_bus,x_right_bus;
    wire [39:0] part_bus;
    piano_preview_cache dut(
        .clk(clk),.rst_n(rst_n),.clear(clear),
        .note_valid(note_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .pitch(pitch),.part_mask(part_mask),
        .read_done(read_done),.read_available(1'b1),
        .read_bpm(16'd112),.loaded(loaded),.bpm(bpm),
        .loop_ticks(loop_ticks),.valid_mask(valid_mask),
        .start_px_bus(start_px_bus),.length_px_bus(length_px_bus),
        .x_left_bus(x_left_bus),.x_right_bus(x_right_bus),
        .part_bus(part_bus)
    );
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        note_valid=1;note_index=0;start_tick=0;
        duration_tick=480;pitch=60;part_mask=2;
        @(negedge clk);
        note_index=1;start_tick=240;duration_tick=240;
        pitch=61;part_mask=1;
        @(negedge clk);
        note_valid=0;read_done=1;
        @(negedge clk);
        read_done=0;
        @(negedge clk);
        if(!loaded || bpm!==112 || loop_ticks!==480 ||
           valid_mask[1:0]!==2'b11 ||
           x_left_bus[9:0]!==284 || x_right_bus[9:0]!==294 ||
           x_left_bus[19:10]!==291 || x_right_bus[19:10]!==299 ||
           length_px_bus[11:0]!==24 || part_bus[3:2]!==1)
            $fatal(1,"preview geometry or metadata wrong");
        clear=1;
        @(negedge clk);
        if(loaded || valid_mask!=0) $fatal(1,"clear failed");
        clear=0;
        // A producer may finish on the same cycle as its only note. The
        // preview must publish that note, not an empty cache.
        note_valid=1;read_done=1;note_index=0;start_tick=96;
        duration_tick=192;pitch=72;part_mask=2;
        @(negedge clk);
        note_valid=0;read_done=0;
        repeat(2) @(negedge clk);
        if(!loaded || valid_mask!==20'b1 || loop_ticks!==288 ||
           x_left_bus[9:0]!==370 || x_right_bus[9:0]!==380)
            $fatal(1,"last-note/done boundary lost preview");
        clear=1;
        @(negedge clk);
        clear=0;note_valid=1;read_done=1;pitch=60;
        @(negedge clk);
        note_valid=0;read_done=0;clear=1;
        @(negedge clk);
        clear=0;
        repeat(2) @(negedge clk);
        if(loaded || valid_mask!=0)
            $fatal(1,"clear did not cancel staged note and completion");
        $display("PASS piano_preview_cache geometry and clear");
        $finish;
    end
endmodule
