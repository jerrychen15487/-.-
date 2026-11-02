`timescale 1ns/1ps
module tb_poly32_light_synth;
    reg clk=0, rst_n=0, sample_tick=0, frame_valid=0;
    reg [7:0] event_type=0,data1=0,data2=0;
    wire signed [15:0] audio_sample;
    wire sample_valid;
    wire [5:0] active_count;
    integer n, cycles, nonzero;
    always #10 clk=~clk;
    poly32_light_synth dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .frame_valid(frame_valid),.event_type(event_type),
        .data1(data1),.data2(data2),.bend_factor_q14(16'd16384),
        .audio_sample(audio_sample),.sample_valid(sample_valid),
        .active_count(active_count)
    );
    task midi;
        input [7:0] kind, a, b;
        begin
            @(negedge clk); event_type=kind; data1=a; data2=b; frame_valid=1;
            @(negedge clk); frame_valid=0;
        end
    endtask
    task tick_and_wait;
        begin
            @(negedge clk); sample_tick=1;
            @(negedge clk); sample_tick=0;
            cycles=0;
            while (!sample_valid && cycles<1024) begin
                @(negedge clk); cycles=cycles+1;
            end
            if (!sample_valid || cycles>200) $fatal(1,"scan missed sample deadline: %0d",cycles);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        for (n=48;n<80;n=n+1) midi(8'h01,n,8'd100);
        if (dut.gate_bits!==32'hffffffff) $fatal(1,"32 Note Ons lost: %h",dut.gate_bits);
        for (n=0;n<32;n=n+1)
            if (dut.note_mem[n]!==n+48) $fatal(1,"slot %0d wrong note",n);
        nonzero=0;
        repeat(80) begin
            tick_and_wait();
            if (audio_sample!=0) nonzero=nonzero+1;
        end
        if (active_count!==6'd32 || nonzero==0)
            $fatal(1,"not 32 sounding notes: count=%0d nonzero=%0d",active_count,nonzero);
        if (dut.phase_mem[0]==dut.phase_mem[1]) $fatal(1,"independent phase failed");
        midi(8'h01,8'd80,8'd100);
        if (dut.note_mem[0]!==7'd80 || dut.gate_bits!==32'hffffffff)
            $fatal(1,"33rd note did not steal one slot");
        midi(8'h02,8'd48,8'd0);
        if (!dut.gate_bits[0]) $fatal(1,"stale Note Off killed stolen note");
        midi(8'h03,8'd64,8'd127);
        midi(8'h02,8'd80,8'd0);
        if (!dut.gate_bits[0] || dut.key_bits[0]) $fatal(1,"pedal hold failed");
        midi(8'h03,8'd64,8'd0);
        if (dut.gate_bits[0]) $fatal(1,"pedal release failed");
        midi(8'h03,8'd123,8'd0);
        if (dut.gate_bits!==0) $fatal(1,"all notes off failed");
        $display("PASS poly32: 32 distinct notes, independent phase, 193-clock deadline, steal, sustain, all-notes-off");
        $finish;
    end
endmodule
