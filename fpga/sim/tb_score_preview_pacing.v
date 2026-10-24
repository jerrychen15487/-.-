`timescale 1ns/1ps
module tb_score_preview_pacing;
    reg pixel_clk=0;
    always #5 pixel_clk=~pixel_clk;
    reg rst_n=0,active=0,paused=0;
    wire [31:0] current_tick;
    wire [11:0] current_scroll_px;
    score_demo_clock clock_dut(
        .pixel_clk(pixel_clk),.rst_n(rst_n),.active(active),
        .paused(paused),
        .bpm(16'd120),.loop_ticks(32'd3840),
        .current_tick(current_tick),.current_scroll_px(current_scroll_px)
    );

    reg [9:0] pix_x=10'd285,pix_y=10'd41;
    reg [11:0] render_scroll_px=0;
    wire [23:0] rgb;
    reg [239:0] start_px=0,length_px=0;
    reg [199:0] x_left=0,x_right=0;
    reg [39:0] part=0;
    reg render_paused=0;
    piano_blocks_demo render_dut(
        .de(1'b1),.pix_x(pix_x),.pix_y(pix_y),
        .scroll_px_in(render_scroll_px),.note_on_mask(128'd0),
        .preview_loaded(1'b1),.preview_paused(render_paused),
        .preview_valid_mask(20'b1),
        .preview_start_px(start_px),.preview_length_px(length_px),
        .preview_x_left(x_left),.preview_x_right(x_right),
        .preview_part(part),.rgb(rgb)
    );
    initial begin
        length_px[11:0]=12'd24;
        x_left[9:0]=10'd284;
        x_right[9:0]=10'd294;
        part[1:0]=2'b10;
        #1;
        if(clock_dut.tick_rate!==25'd960)
            $fatal(1,"preview must run at half speed");
        if(rgb===24'h218A7D)
            $fatal(1,"first note must not already occupy display at tick 0");
        render_scroll_px=12'd5;
        #1;
        if(rgb!==24'h218A7D)
            $fatal(1,"first note must enter near the top shortly after start");
        render_scroll_px=12'd360;
        pix_y=10'd390;
        #1;
        if(rgb!==24'h218A7D)
            $fatal(1,"first note must approach the keyboard after lead-in");
        repeat(3) @(negedge pixel_clk);
        rst_n=1;active=1;
        repeat(3) @(negedge pixel_clk);
        if(clock_dut.loop_terminal_q!==32'd11129)
            $fatal(1,"preview lead-in and scoring tail changed");
        repeat(250000) @(negedge pixel_clk);
        if(current_tick<9 || current_tick>10)
            $fatal(1,"half-speed clock advanced %0d ticks in 10 ms",current_tick);
        if(current_scroll_px!=0)
            $fatal(1,"preview scroll should advance only after enough ticks");
        repeat(500000) @(negedge pixel_clk);
        if(current_scroll_px!==((current_tick*32'd3291)>>16))
            $fatal(1,"scroll accumulator disagrees with score tick scale");
        paused=1;
        begin: pause_hold
            reg [31:0] held_tick;
            reg [11:0] held_scroll;
            held_tick=current_tick;
            held_scroll=current_scroll_px;
            repeat(100000) @(negedge pixel_clk);
            if(current_tick!==held_tick || current_scroll_px!==held_scroll)
                $fatal(1,"pause must freeze tick and block position");
            paused=0;
            repeat(100000) @(negedge pixel_clk);
            if(current_tick<=held_tick)
                $fatal(1,"resume must continue instead of restarting");
        end
        render_paused=1;pix_x=10'd594;pix_y=10'd20;
        #1;
        if(rgb!==24'hFFFFFF)
            $fatal(1,"pause indicator must be visible on HDMI");
        $display("PASS preview half speed and top-entry lead-in");
        $finish;
    end
endmodule
