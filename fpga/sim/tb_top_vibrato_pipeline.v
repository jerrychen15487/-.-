`timescale 1ns/1ps
module tb_top_vibrato_pipeline;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    top dut(.sys_clk(clk),.sys_rst_n(rst_n),.view_key_n(1'b1),
            .spectrum_key_n(1'b1),.uart_rx_i(1'b1),
            .score_uart_rx_i(1'b1),.sd_miso(1'b1),
            .spi_sclk_i(1'b0),.spi_mosi_i(1'b0),.spi_cs_n_i(1'b1));

    task check_bend;
        input [13:0] bend;
        input [6:0] depth;
        input [31:0] phase;
        input [13:0] expected;
        begin
            force dut.pitch_bend=bend;
            force dut.vibrato_depth=depth;
            force dut.vibrato_phase=phase;
            repeat(4) @(negedge clk);
            if (dut.effective_pitch_bend_q !== expected)
                $fatal(1,"bend=%0d depth=%0d phase=%h got=%0d expected=%0d",
                       bend,depth,phase,dut.effective_pitch_bend_q,expected);
        end
    endtask

    task check_factor;
        input [13:0] bend;
        input [15:0] expected;
        begin
            force dut.effective_pitch_bend_q=bend;
            repeat(4) @(negedge clk);
            if(dut.bend_factor_q14!==expected)
                $fatal(1,"interpolated bend=%0d factor=%0d expected=%0d",
                       bend,dut.bend_factor_q14,expected);
            release dut.effective_pitch_bend_q;
        end
    endtask

    initial begin
        force dut.voice_rst_n=1'b0;
        repeat(3) @(negedge clk);
        if (dut.effective_pitch_bend_q !== 14'd8192 ||
            dut.bend_factor_q14 !== 16'd16384 ||
            dut.pitch_bend_q1 !== 14'd8192 ||
            dut.pitch_bend_q2 !== 14'd8192)
            $fatal(1,"expression pipeline reset mismatch");
        force dut.voice_rst_n=1'b1;
        check_bend(14'd8192,7'd0,32'd0,14'd8192);
        check_bend(14'd8192,7'd127,32'h40000000,14'd10208);
        check_bend(14'd8192,7'd127,32'hbf800000,14'd6175);
        check_bend(14'd16383,7'd127,32'h40000000,14'd16383);
        check_bend(14'd0,7'd127,32'hbf800000,14'd0);
        check_bend(14'd0,7'd0,32'd0,14'd0);
        repeat(3) @(negedge clk);
        if (dut.bend_factor_q14 !== 16'd14596)
            $fatal(1,"lower bend endpoint mismatch got=%0d",
                   dut.bend_factor_q14);
        check_bend(14'd8192,7'd0,32'd0,14'd8192);
        repeat(3) @(negedge clk);
        if (dut.bend_factor_q14 !== 16'd16384)
            $fatal(1,"center bend endpoint mismatch got=%0d",
                   dut.bend_factor_q14);
        check_factor(14'd512,16'd14703);
        check_factor(14'd8704,16'd16503);
        check_factor(14'd16383,16'd18390);
        $display("PASS top vibrato pipeline: reset, CC1 extremes, saturation, dynamic bend, endpoints");
        $finish;
    end
endmodule
