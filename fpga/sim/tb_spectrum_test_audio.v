`timescale 1ns/1ps
module tb_spectrum_test_audio;
    reg clk=0,rst_n=0;
    reg [3:0] tick_div=0;
    wire sample_tick=(tick_div==4'd15);
    always #10 clk=~clk;
    always @(posedge clk) tick_div<=tick_div+1'b1;
    wire frame_valid;
    wire [7:0] event_type,data1,data2;
    spectrum_test_pattern pattern(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .frame_valid(frame_valid),.event_type(event_type),
        .data1(data1),.data2(data2)
    );
    wire [6:0] n0,n1,n2,n3,v0,v1,v2,v3;
    wire [3:0] gate,retrigger,finished;
    poly_voice_ctrl voices(
        .clk(clk),.rst_n(rst_n),.frame_valid(frame_valid),
        .event_type(event_type),.data1(data1),.data2(data2),
        .voice_finished(finished),.note0(n0),.note1(n1),
        .note2(n2),.note3(n3),.velocity0(v0),.velocity1(v1),
        .velocity2(v2),.velocity3(v3),.gate(gate),
        .retrigger(retrigger)
    );
    wire signed [15:0] s0,s1,s2,s3;
    wire [7:0] e0,e1,e2,e3;
    basic_dds_synth a0(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(n0),.velocity(v0),.gate(gate[0]),.retrigger(retrigger[0]),
        .timbre_select(1'b1),.bend_factor_q14(16'd16384),
        .audio_sample(s0),.envelope_level(e0),.voice_finished(finished[0]));
    basic_dds_synth a1(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(n1),.velocity(v1),.gate(gate[1]),.retrigger(retrigger[1]),
        .timbre_select(1'b1),.bend_factor_q14(16'd16384),
        .audio_sample(s1),.envelope_level(e1),.voice_finished(finished[1]));
    basic_dds_synth a2(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(n2),.velocity(v2),.gate(gate[2]),.retrigger(retrigger[2]),
        .timbre_select(1'b1),.bend_factor_q14(16'd16384),
        .audio_sample(s2),.envelope_level(e2),.voice_finished(finished[2]));
    basic_dds_synth a3(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .note(n3),.velocity(v3),.gate(gate[3]),.retrigger(retrigger[3]),
        .timbre_select(1'b1),.bend_factor_q14(16'd16384),
        .audio_sample(s3),.envelope_level(e3),.voice_finished(finished[3]));
    wire signed [17:0] mix={{2{s0[15]}},s0}+{{2{s1[15]}},s1}+
        {{2{s2[15]}},s2}+{{2{s3[15]}},s3};
    wire signed [15:0] audio_sample=mix>>>2;
    wire signed [15:0] audio_effected;
    echo_delay delay_bypass(.clk(clk),.rst_n(rst_n),
        .sample_tick(sample_tick),.enable(1'b0),
        .dry_in(audio_sample),.audio_out(audio_effected));
    wire [255:0] spectrum_bins;
    wire updated;
    fft64_spectrum fft(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .audio_sample(audio_effected),.magnitude_bus(spectrum_bins),
        .update_toggle(updated));
    integer sample_count=0, updates=0, i;
    reg seen_update=0;
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        while(sample_count<3200) begin
            @(negedge clk);
            if(sample_tick) sample_count=sample_count+1;
            if(updated!=seen_update) begin
                seen_update=updated;
                updates=updates+1;
                $write("FFT update %0d:",updates);
                for(i=1;i<24;i=i+1)
                    $write(" %0d:%0d",i,spectrum_bins[i*8+:8]);
                $write("\n");
                if(updates==2 &&
                   !(spectrum_bins[4*8+:8]>spectrum_bins[3*8+:8] &&
                     spectrum_bins[4*8+:8]>spectrum_bins[5*8+:8] &&
                     spectrum_bins[6*8+:8]>spectrum_bins[5*8+:8] &&
                     spectrum_bins[6*8+:8]>spectrum_bins[7*8+:8] &&
                     spectrum_bins[9*8+:8]>spectrum_bins[8*8+:8] &&
                     spectrum_bins[9*8+:8]>spectrum_bins[10*8+:8] &&
                     spectrum_bins[14*8+:8]>spectrum_bins[13*8+:8] &&
                     spectrum_bins[14*8+:8]>spectrum_bins[15*8+:8]))
                    $fatal(1,"four independent fundamental peaks missing");
            end
        end
        if(gate!=4'b1111 || updates<2)
            $fatal(1,"missing active voices or spectrum gate=%b updates=%0d",gate,updates);
        $display("PASS four real DDS voices reached the FPGA FFT");
        $finish;
    end
endmodule
