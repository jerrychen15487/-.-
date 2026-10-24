`timescale 1ns/1ps
module tb_midi_basic_synth;
    reg sys_clk = 1'b0;
    reg sys_rst_n = 1'b0;
    reg uart_rx_i = 1'b1;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN, debug_gate;
    integer errors = 0;

    top dut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n), .uart_rx_i(uart_rx_i),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN),
        .PA_EN(PA_EN), .debug_gate(debug_gate)
    );

    always #10 sys_clk = ~sys_clk;

    function [7:0] crc8_byte;
        input [7:0] crc_in;
        input [7:0] byte_in;
        integer i;
        reg [7:0] c;
        begin
            c = crc_in ^ byte_in;
            for (i = 0; i < 8; i = i + 1)
                c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8_byte = c;
        end
    endfunction

    task uart_byte;
        input [7:0] value;
        integer i;
        begin
            uart_rx_i = 1'b0; #1000;
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_i = value[i]; #1000;
            end
            uart_rx_i = 1'b1; #1000;
        end
    endtask

    task send_frame;
        input [7:0] seq;
        input [7:0] kind;
        input [7:0] ch;
        input [7:0] d1;
        input [7:0] d2;
        input corrupt_crc;
        reg [7:0] crc;
        begin
            crc = 8'h00;
            crc = crc8_byte(crc, 8'hA5);
            crc = crc8_byte(crc, 8'h5A);
            crc = crc8_byte(crc, seq);
            crc = crc8_byte(crc, kind);
            crc = crc8_byte(crc, ch);
            crc = crc8_byte(crc, d1);
            crc = crc8_byte(crc, d2);
            uart_byte(8'hA5); uart_byte(8'h5A); uart_byte(seq); uart_byte(kind);
            uart_byte(ch); uart_byte(d1); uart_byte(d2);
            uart_byte(corrupt_crc ? (crc ^ 8'h01) : crc);
        end
    endtask

    initial begin
        // Allow the 1024-cycle internal power-on reset to complete.
        #200; sys_rst_n = 1'b1; #25000;
        send_frame(8'h00, 8'h01, 8'h00, 8'd60, 8'd90, 1'b0);
        send_frame(8'h01, 8'h01, 8'h00, 8'd64, 8'd90, 1'b0);
        send_frame(8'h02, 8'h01, 8'h00, 8'd67, 8'd90, 1'b0);
        send_frame(8'h03, 8'h01, 8'h00, 8'd72, 8'd90, 1'b0);
        #5000;
        if (dut.u_voice_ctrl.gate != 4'b1111) begin $display("ERROR: four voices are not active"); errors = errors + 1; end
        if ((dut.u_voice_ctrl.note0 != 7'd60) || (dut.u_voice_ctrl.note1 != 7'd64) ||
            (dut.u_voice_ctrl.note2 != 7'd67) || (dut.u_voice_ctrl.note3 != 7'd72)) begin
            $display("ERROR: wrong four-voice allocation"); errors = errors + 1;
        end

        send_frame(8'h10, 8'h04, 8'h00, 8'h7F, 8'h7F, 1'b0);
        #5000;
        if (dut.pitch_bend != 14'd16383 ||
            dut.u_voice0.phase_step_bent <= dut.u_voice0.phase_step_base_q ||
            dut.u_voice_ctrl.gate != 4'b1111) begin
            $display("ERROR: active voices did not bend upward"); errors = errors + 1;
        end
        send_frame(8'h11, 8'h04, 8'h00, 8'h00, 8'h40, 1'b0);
        #5000;
        if (dut.pitch_bend != 14'd8192 ||
            dut.u_voice0.phase_step_bent != dut.u_voice0.phase_step_base_q) begin
            $display("ERROR: pitch bend did not return to exact center"); errors = errors + 1;
        end

        send_frame(8'h04, 8'h02, 8'h00, 8'd64, 8'd0, 1'b0);
        #5000;
        if (dut.u_voice_ctrl.gate != 4'b1101) begin $display("ERROR: individual Note Off failed"); errors = errors + 1; end

        send_frame(8'h05, 8'h03, 8'h00, 8'd123, 8'd0, 1'b0);
        #5000;
        if (debug_gate) begin $display("ERROR: All Notes Off failed"); errors = errors + 1; end

        send_frame(8'h06, 8'h01, 8'h00, 8'd64, 8'd100, 1'b1);
        #5000;
        if (debug_gate) begin $display("ERROR: bad CRC frame was accepted"); errors = errors + 1; end

        if (PA_EN !== 1'b0) begin $display("ERROR: amplifier is not enabled"); errors = errors + 1; end
        if (errors == 0) $display("PASS: UART, CRC, four voices, live pitch bend, Note Off and PA_EN checks passed");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
