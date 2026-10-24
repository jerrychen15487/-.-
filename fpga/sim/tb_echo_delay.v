`timescale 1ns/1ps
module tb_echo_delay;
    reg clk=0,rst_n=0,sample_tick=0,enable=0;
    reg signed [15:0] dry_in=0;
    wire signed [15:0] audio_out;
    integer n;
    always #10 clk=~clk;
    echo_delay #(.DELAY_BITS(3)) dut (
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .enable(enable),.dry_in(dry_in),.audio_out(audio_out)
    );
    task sample;
        input signed [15:0] value;
        begin
            @(negedge clk); dry_in=value; sample_tick=1;
            @(negedge clk); sample_tick=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        // Dry signal is pipelined; memory must not leak uninitialized data.
        sample(16'sd2000); sample(0);
        if (audio_out !== 16'sd2000)
            $fatal(1,"dry output did not preserve first pulse");
        enable=1;
        for(n=0;n<9;n=n+1) sample(0);
        if (audio_out !== 16'sd1000)
            $fatal(1,"delayed half-level pulse missing: %0d",audio_out);
        sample(0);
        if (audio_out !== 16'sd0)
            $fatal(1,"unexpected feedback/repeat");
        // Saturate rather than wrapping when a new pulse meets an old one.
        sample(16'sd30000);
        for(n=0;n<8;n=n+1) sample(0);
        sample(16'sd30000);
        sample(0);
        if (audio_out !== 16'sh7fff)
            $fatal(1,"positive mix did not saturate: %0d",audio_out);
        $display("PASS echo dry bypass, one delayed repeat, saturation");
        $finish;
    end
endmodule
