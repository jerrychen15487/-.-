`timescale 1ns/1ps
module tb_f5_score_clock;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0,pause=0;
    reg [15:0] bpm=20;
    reg [31:0] duration_ticks=10;
    wire [1:0] state;
    wire [2:0] countdown;
    wire [31:0] current_tick;
    wire tick_ce,running,complete;
    f5_score_clock #(.CLOCK_HZ(6000),.COUNT_IN_SECONDS(3)) dut(.*);
    integer ticks=0;
    always @(posedge clk) if(tick_ce) ticks=ticks+1;
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        start=1; @(negedge clk); start=0;
        if(countdown!=3 || state!=1) $fatal(1,"count-in did not start");
        repeat(5999) @(negedge clk);
        if(countdown!=2) $fatal(1,"first count-in second missing");
        pause=1;
        repeat(40) @(negedge clk);
        if(countdown!=2 || state!=1) $fatal(1,"count-in did not pause");
        pause=0;
        repeat(12002) @(negedge clk);
        if(!running || state!=2 || countdown!=0)
            $fatal(1,"playback did not start after count-in");
        repeat(70) @(negedge clk);
        pause=1;
        begin : hold_check
            reg [31:0] held_tick;
            integer held_pulses;
            held_tick=current_tick; held_pulses=ticks;
            repeat(50) @(negedge clk);
            if(current_tick!=held_tick || ticks!=held_pulses)
                $fatal(1,"pause advanced score time");
        end
        pause=0;
        wait(complete);
        if(current_tick!=10 || ticks!=10)
            $fatal(1,"expected exact completion at tick 10, got %0d/%0d",
                current_tick,ticks);
        start=1; @(negedge clk); start=0;
        if(state!=1 || current_tick!=0)
            $fatal(1,"restart did not reload count-in and tick");
        $display("PASS F5 score clock: count-in, pause/resume, exact duration, restart");
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
