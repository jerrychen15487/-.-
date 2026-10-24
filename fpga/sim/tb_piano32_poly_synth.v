`timescale 1ns/1ps
module tb_piano32_poly_synth;
    reg clk=0, rst_n=0, sample_tick=0, enable=1;
    reg [3:0] retrigger_bus=0;
    reg [127:0] step_bus={4{32'd23012828}}; // MIDI 60 at 48.828125 kHz
    reg [31:0] envelope_bus={4{8'd255}};
    reg [27:0] velocity_bus={4{7'd127}};
    reg [27:0] note_bus={4{7'd60}};
    wire signed [15:0] sample0,sample1,sample2,sample3;
    wire sample_valid,overrun;
    integer cycles, i, expected_int, error_abs;
    reg signed [15:0] first_sample;
    real expected, angle, multiplier, level, pi;

    always #10 clk=~clk;
    piano32_poly_synth dut (
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.enable(enable),
        .step_bus(step_bus),.retrigger_bus(retrigger_bus),
        .envelope_bus(envelope_bus),.velocity_bus(velocity_bus),
        .note_bus(note_bus),.sample0(sample0),.sample1(sample1),
        .sample2(sample2),.sample3(sample3),
        .sample_valid(sample_valid),.overrun(overrun)
    );

    function real partial_level;
        input integer n;
        begin
            case(n)
                1:partial_level=1.0; 2:partial_level=0.32;
                3:partial_level=0.22; 4:partial_level=0.16;
                5:partial_level=0.04; 6:partial_level=0.16;
                7:partial_level=0.05; 8:partial_level=0.025;
                9:partial_level=0.15; 10:partial_level=0.02;
                11:partial_level=0.008; 12:partial_level=0.008;
                default:partial_level=0.006*144.0/(n*n);
            endcase
        end
    endfunction

    task send_frame;
        begin
            @(negedge clk); sample_tick=1;
            @(negedge clk); sample_tick=0;
            cycles=0;
            while (!sample_valid && cycles<1024) begin
                @(negedge clk); cycles=cycles+1;
            end
            if (!sample_valid || overrun || cycles>=1024)
                $fatal(1,"four-voice 32-partial deadline missed cycles=%0d overrun=%b",cycles,overrun);
        end
    endtask

    initial begin
        pi=3.141592653589793;
        repeat(4) @(negedge clk);
        rst_n=1;
        @(negedge clk); retrigger_bus=4'b1111;
        @(negedge clk); retrigger_bus=0;
        send_frame();
        if (sample0 !== sample1 || sample0 !== sample2 || sample0 !== sample3)
            $fatal(1,"identical four voices produced different samples");
        expected=0.0;
        for(i=1;i<=32;i=i+1) begin
            multiplier=i*$sqrt((1.0+0.00035*i*i)/(1.0+0.00035));
            angle=0.23*multiplier;
            expected=expected+partial_level(i)*$sin(angle);
        end
        expected_int=$rtoi(expected*32768.0/4.0*255.0/256.0*127.0/128.0);
        error_abs=sample0-expected_int;
        if (error_abs<0) error_abs=-error_abs;
        if (error_abs>180)
            $fatal(1,"candidate first-sample math mismatch got=%0d ideal=%0d",sample0,expected_int);
        $display("four_voice_C4 sample=%0d ideal=%0d cycles=%0d",sample0,expected_int,cycles);
        first_sample=sample0;
        send_frame();
        if (sample0 === first_sample)
            $fatal(1,"phase did not advance on the second sample");

        // Simultaneous, different notes must not share an oscillator phase.
        note_bus={7'd72,7'd67,7'd64,7'd60};
        step_bus={32'd46025656,32'd34512342,32'd28995098,32'd23012828};
        retrigger_bus=4'b1111;
        @(negedge clk); retrigger_bus=0;
        send_frame();
        send_frame();
        if (sample0 === sample1 || sample1 === sample2 || sample2 === sample3)
            $fatal(1,"different pitches unexpectedly produced identical samples");
        if ((^{sample3,sample2,sample1,sample0}) === 1'bx)
            $fatal(1,"chord contains an unknown sample");

        // Same 1024-clock budget at the top of the 88-key range. Max partial
        // must fall to five so high harmonics cannot fold below Nyquist.
        note_bus[27:21]=7'd108;
        step_bus[127:96]=32'd368205249;
        retrigger_bus=4'b1000;
        @(negedge clk); retrigger_bus=0;
        send_frame();
        if (dut.max_partial(7'd108) != 6'd5 || dut.max_partial(7'd60) != 6'd32)
            $fatal(1,"note-dependent harmonic cutoff incorrect");
        if (^sample3 === 1'bx) $fatal(1,"high voice sample unknown");

        @(negedge clk); enable=0; sample_tick=1;
        @(negedge clk); sample_tick=0;
        if ({sample3,sample2,sample1,sample0} !== 64'd0)
            $fatal(1,"disabled piano samples not cleared");
        $display("PASS piano32: independent four voices, advancing phase, 32 partials, sample deadline, high-note cutoff, disable");
        $finish;
    end
endmodule
