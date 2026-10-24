`timescale 1ns/1ps
module tb_dds_third_phase_pipe;
    reg clk=0,rst_n=0,sample_tick=0,gate=0,retrigger=0;
    reg [6:0] note=7'd60;
    reg [15:0] bend_factor_q14=16'd16384;
    integer cycle,checks=0;
    always #10 clk=~clk;
    basic_dds_synth dut(.clk(clk),.rst_n(rst_n),
        .sample_tick(sample_tick),.note(note),.velocity(7'd100),
        .gate(gate),.retrigger(retrigger),.timbre_select(1'b0),
        .bend_factor_q14(bend_factor_q14),.audio_sample(),
        .envelope_level(),.voice_finished(),.phase_out(),
        .phase_step_out());
    initial begin
        repeat(5) @(negedge clk);
        rst_n=1;gate=1;retrigger=1;
        for(cycle=0;cycle<160000;cycle=cycle+1) begin
            @(negedge clk);
            sample_tick=(cycle%1024)==0;
            retrigger=0;
            if(cycle==30000) note=7'd48;
            if(cycle==60000) bend_factor_q14=16'd17100;
            if(cycle==90000) begin gate=0;end
            if(cycle==110000) begin
                gate=1;retrigger=1;note=7'd72;
            end
            if(sample_tick && cycle>4096) begin
                if(dut.piano_phase_3_q!==
                   ((dut.phase<<1)+dut.phase))
                    $fatal(1,"third-harmonic phase stale at sample %0d",
                           cycle);
                if(dut.piano_sine_3!==
                   dut.sine_interpolated((dut.phase<<1)+dut.phase))
                    $fatal(1,"third-harmonic sine changed at sample %0d",
                           cycle);
                checks=checks+1;
            end
        end
        $display("PASS DDS third-harmonic sample equivalence: %0d checks",
                 checks);
        $finish;
    end
endmodule
