`timescale 1ns/1ps
module tb_dds_sample_trace;
    reg clk=0,rst_n=0,sample_tick=0,gate=0,retrigger=0;
    reg timbre_select=0;
    reg [6:0] note=7'd60,velocity=7'd100;
    reg [15:0] bend_factor_q14=16'd16384;
    wire signed [15:0] audio_sample;
    wire [7:0] envelope_level;
    integer cycle;
    always #10 clk=~clk;
    basic_dds_synth dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(note),.velocity(velocity),.gate(gate),
        .retrigger(retrigger),.timbre_select(timbre_select),
        .bend_factor_q14(bend_factor_q14),
        .audio_sample(audio_sample),.envelope_level(envelope_level),
        .voice_finished(),.phase_out(),.phase_step_out()
    );
    initial begin
        repeat(5) @(negedge clk);
        rst_n=1;gate=1;retrigger=1;
        for(cycle=0;cycle<200000;cycle=cycle+1) begin
            @(negedge clk);
            sample_tick=(cycle%1024)==0;
            retrigger=(cycle==50000 || cycle==95000);
            if(cycle==30000) note=7'd48;
            if(cycle==60000) bend_factor_q14=16'd17000;
            if(cycle==90000) timbre_select=1;
            if(cycle==120000) gate=0;
            if(cycle==150000) begin
                gate=1;note=7'd72;velocity=7'd70;
            end
            #1;
            if(sample_tick)
                $display("%0d %0d %0d",cycle,audio_sample,envelope_level);
        end
        $finish;
    end
endmodule
