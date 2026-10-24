`timescale 1ns/1ps
module tb_dds_phase_pipe_equiv;
    reg clk=0,rst_n=0,sample_tick=0,gate=0,retrigger=0,timbre_select=0;
    reg [6:0] note=60,velocity=100;
    reg [15:0] bend_factor_q14=16'd16384;
    wire signed [15:0] audio_new,audio_ref;
    wire [7:0] envelope_new,envelope_ref;
    wire finished_new,finished_ref;
    integer cycle=0,checks=0;
    always #10 clk=~clk;
    basic_dds_synth dut(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(note),.velocity(velocity),.gate(gate),.retrigger(retrigger),
        .timbre_select(timbre_select),.bend_factor_q14(bend_factor_q14),
        .audio_sample(audio_new),.envelope_level(envelope_new),
        .voice_finished(finished_new));
    basic_dds_synth_ref golden(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(note),.velocity(velocity),.gate(gate),.retrigger(retrigger),
        .timbre_select(timbre_select),.bend_factor_q14(bend_factor_q14),
        .audio_sample(audio_ref),.envelope_level(envelope_ref),
        .voice_finished(finished_ref));
    initial begin
        repeat(5) @(negedge clk); rst_n=1; gate=1; retrigger=1;
        for(cycle=0;cycle<200000;cycle=cycle+1) begin
            @(negedge clk);
            sample_tick=(cycle%1024)==0;
            retrigger=0;
            if(cycle==30000) note=50;
            if(cycle==60000) bend_factor_q14=16'd17000;
            if(cycle==90000) timbre_select=1;
            if(cycle==120000) gate=0;
            #1;
            if(sample_tick && cycle>4096) begin
                if(audio_new!==audio_ref || envelope_new!==envelope_ref ||
                   finished_new!==finished_ref) begin
                    $display("FAIL cycle=%0d new=%0d ref=%0d",cycle,
                        audio_new,audio_ref);
                    $fatal(1);
                end
                checks=checks+1;
            end
        end
        $display("PASS DDS phase-pipe sample equivalence: %0d checks",checks);
        $finish;
    end
endmodule
