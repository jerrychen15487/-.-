`timescale 1ns/1ps
module tb_spectrum_mode_key;
    reg clk=0, rst_n=0, key_n=1;
    wire test_mode,echo_enabled;
    always #10 clk=~clk;
    spectrum_mode_key #(.DEBOUNCE_CYCLES(4),.LONG_PRESS_UNITS(12)) dut (
        .clk(clk),.rst_n(rst_n),.key_n(key_n),
        .test_mode(test_mode),.echo_enabled(echo_enabled)
    );
    task settle;
        input integer cycles;
        integer i;
        begin
            for (i=0;i<cycles;i=i+1) @(negedge clk);
        end
    endtask
    initial begin
        settle(3); rst_n=1;
        settle(3);
        if (test_mode !== 0 || echo_enabled !== 0)
            $fatal(1,"must boot in dry normal mode");
        key_n=0; settle(2); key_n=1; settle(8);
        if (test_mode !== 0) $fatal(1,"bounce toggled mode");
        key_n=0; settle(9);
        if (test_mode !== 0) $fatal(1,"short press toggled before release");
        key_n=1; settle(9);
        if (test_mode !== 1 || echo_enabled !== 0)
            $fatal(1,"short release did not enter test");
        key_n=0; settle(60);
        if (test_mode !== 1 || echo_enabled !== 0)
            $fatal(1,"held key acted before release");
        key_n=1; settle(9);
        if (test_mode !== 1 || echo_enabled !== 1)
            $fatal(1,"long release did not toggle echo alone");
        key_n=0; settle(9); key_n=1; settle(9);
        if (test_mode !== 0 || echo_enabled !== 1)
            $fatal(1,"second short release did not restore play");
        key_n=0; settle(60); key_n=1; settle(9);
        if (test_mode !== 0 || echo_enabled !== 0)
            $fatal(1,"second long release did not disable echo");
        rst_n=0; settle(2);
        if (test_mode !== 0 || echo_enabled !== 0)
            $fatal(1,"reset did not restore dry play");
        $display("PASS KEY2 short=test, long=echo, bounce and reset");
        $finish;
    end
endmodule
