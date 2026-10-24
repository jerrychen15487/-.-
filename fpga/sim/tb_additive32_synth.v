`timescale 1ns/1ps
module tb_additive32_synth;
    reg clk=0,rst_n=0,sample_tick=0,enable=1;
    reg [31:0] phase=0;
    reg [7:0] envelope=255;
    reg [6:0] velocity=127;
    wire signed [15:0] audio_sample;
    wire sample_valid,overrun;
    integer cycles, n, expected_int, error_abs;
    reg [31:0] visited_partials = 0;
    real angle, expected, pi;
    always #10 clk=~clk;
    additive32_synth dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .enable(enable),.phase(phase),.envelope(envelope),
        .velocity(velocity),.audio_sample(audio_sample),
        .sample_valid(sample_valid),.overrun(overrun)
    );
    always @(posedge clk) begin
        if (rst_n && dut.state == 3'd4 && dut.partial >= 1 &&
            dut.partial <= 32)
            visited_partials[dut.partial-1] <= 1'b1;
    end
    task run_case;
        input [31:0] test_phase;
        input [7:0] test_envelope;
        input [6:0] test_velocity;
        begin
            @(negedge clk);
            visited_partials=0;
            phase=test_phase; envelope=test_envelope;
            velocity=test_velocity; sample_tick=1;
            @(negedge clk); sample_tick=0;
            cycles=0;
            while (!sample_valid && cycles<1024) begin
                @(negedge clk); cycles=cycles+1;
            end
            if (!sample_valid || cycles>=1024 || overrun)
                $fatal(1,"32 partial frame missed deadline: %0d",cycles);
            if (visited_partials !== 32'hffffffff)
                $fatal(1,"not all 32 partials were computed: %h",visited_partials);
            expected=0.0;
            for(n=1;n<=32;n=n+1) begin
                angle=2.0*pi*test_phase*n/4294967296.0;
                expected=expected+$sin(angle)/n;
            end
            expected=expected*32768.0/4.0*test_envelope/256.0*
                     test_velocity/128.0;
            expected_int=$rtoi(expected);
            error_abs=audio_sample-expected_int;
            if(error_abs<0) error_abs=-error_abs;
            if(error_abs>90)
                $fatal(1,"sample mismatch phase=%h got=%0d ideal=%0d",
                       test_phase,audio_sample,expected_int);
            $display("partial=32 phase=%h got=%0d ideal=%0d cycles=%0d",
                     test_phase,audio_sample,expected_int,cycles);
        end
    endtask
    initial begin
        pi=3.141592653589793;
        repeat(3) @(negedge clk);
        rst_n=1;
        run_case(32'h10000000,8'd255,7'd127);
        run_case(32'h18000000,8'd180,7'd90);
        run_case(32'h38000000,8'd255,7'd127);
        @(negedge clk); enable=0; sample_tick=1;
        @(negedge clk); sample_tick=0;
        if(audio_sample!==0) $fatal(1,"disabled output not zero");
        $display("PASS additive32: 32 weighted partials, deadline, gain, off");
        $finish;
    end
endmodule
