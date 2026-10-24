`timescale 1ns/1ps
module tb_spi_midi_frame_rx;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg spi_sclk_i = 1'b0;
    reg spi_mosi_i = 1'b0;
    reg spi_cs_n_i = 1'b1;
    wire spi_ready_o;
    wire frame_valid;
    wire [7:0] event_type, route, midi_parameter, value;
    integer received = 0;
    integer burst_seen = 0;
    integer burst_index;
    reg burst_active = 1'b0;
    reg [47:0] wanted;

    // Same 16-event phrase as esp32_local/main/sim_input.c, repeated four
    // times. USB-MIDI Note On with velocity zero becomes SPI Note Off.
    function [47:0] expected_burst_frame;
        input integer index;
        begin
            case (index % 16)
                0:  expected_burst_frame = 48'h01_00_3C_20_00_00;
                1:  expected_burst_frame = 48'h02_00_3C_40_00_00;
                2:  expected_burst_frame = 48'h01_00_3C_64_00_00;
                3:  expected_burst_frame = 48'h02_00_3C_00_00_00;
                4:  expected_burst_frame = 48'h03_00_40_7F_00_00;
                5:  expected_burst_frame = 48'h01_00_3C_50_00_00;
                6:  expected_burst_frame = 48'h01_00_40_5A_00_00;
                7:  expected_burst_frame = 48'h01_00_43_64_00_00;
                8:  expected_burst_frame = 48'h02_00_3C_40_00_00;
                9:  expected_burst_frame = 48'h02_00_40_40_00_00;
                10: expected_burst_frame = 48'h02_00_43_40_00_00;
                11: expected_burst_frame = 48'h03_00_40_20_00_00;
                12: expected_burst_frame = 48'h03_00_40_00_00_00;
                13: expected_burst_frame = 48'h03_00_43_7F_00_00;
                14: expected_burst_frame = 48'h03_00_43_00_00_00;
                15: expected_burst_frame = 48'h03_00_01_00_00_00;
            endcase
        end
    endfunction

    always #10 clk = ~clk; // 50 MHz FPGA clock

    spi_midi_frame_rx dut (
        .clk(clk), .rst_n(rst_n), .spi_sclk_i(spi_sclk_i),
        .spi_mosi_i(spi_mosi_i), .spi_cs_n_i(spi_cs_n_i),
        .spi_ready_o(spi_ready_o), .frame_valid(frame_valid),
        .event_type(event_type), .route(route),
        .midi_parameter(midi_parameter), .value(value)
    );

    always @(posedge clk) begin
        if (frame_valid) begin
            if (burst_active) begin
                if (burst_seen >= 64)
                    $fatal(1, "unexpected extra frame in 64-event burst");
                wanted = expected_burst_frame(burst_seen);
                if ({event_type, route, midi_parameter, value} !== wanted[47:16])
                    $fatal(1, "64-event mismatch index=%0d got=%h expected=%h",
                           burst_seen, {event_type, route, midi_parameter, value}, wanted[47:16]);
                burst_seen = burst_seen + 1;
            end
            received = received + 1;
        end
    end

    task send_bits;
        input [55:0] payload;
        input integer count;
        integer i;
        begin
            if (!spi_ready_o) $fatal(1, "READY was not high before CS");
            spi_cs_n_i = 1'b0;
            #100;
            if (spi_ready_o !== 1'b0)
                $fatal(1, "READY must be low after CS starts, before its 48 bits finish");
            for (i = count - 1; i >= 0; i = i - 1) begin
                spi_mosi_i = payload[i];
                #50; spi_sclk_i = 1'b1;
                #50; spi_sclk_i = 1'b0;
            end
            #100; spi_cs_n_i = 1'b1;
            #200;
            if (!spi_ready_o) $fatal(1, "READY did not recover after CS");
        end
    endtask

    initial begin
        #200; rst_n = 1'b1; #200;
        if (!spi_ready_o) $fatal(1, "READY did not rise after reset");
        send_bits({8'h00, 48'h01_00_3C_64_00_00}, 48);
        if (received != 1 || event_type != 8'h01 || route != 8'h00 ||
            midi_parameter != 8'h3C || value != 8'h64)
            $fatal(1, "valid Note On lost or corrupted");
        send_bits({8'h00, 48'h02_00_3C_00_00_00}, 48);
        if (received != 2 || event_type != 8'h02)
            $fatal(1, "valid Note Off lost");
        send_bits({8'h00, 48'h03_00_40_60_00_00}, 48);
        if (received != 3 || event_type != 8'h03 || value != 8'h60)
            $fatal(1, "CC64 value lost");
        send_bits({8'h00, 48'h04_00_00_40_00_00}, 48);
        if (received != 4 || event_type != 8'h04 ||
            midi_parameter != 8'h00 || value != 8'h40)
            $fatal(1, "14-bit pitch bend lost or corrupted");
        send_bits({8'h00, 48'h05_00_02_00_00_00}, 48);
        if (received != 5 || event_type != 8'h05 ||
            midi_parameter != 8'h02 || value != 8'h00)
            $fatal(1, "Program Change lost or corrupted");
        send_bits({8'h00, 48'h01_00_3C_64_00_00}, 40);
        if (received != 5) $fatal(1, "short frame accepted");
        send_bits(56'h00_01_00_3C_64_00_00, 56);
        if (received != 5) $fatal(1, "long frame accepted");
        send_bits({8'h00, 48'h01_00_3C_64_01_00}, 48);
        if (received != 5) $fatal(1, "nonzero value_hi accepted");
        send_bits({8'h00, 48'h06_00_3C_64_00_00}, 48);
        if (received != 5) $fatal(1, "unassigned type accepted");
        burst_active = 1'b1;
        for (burst_index = 0; burst_index < 64; burst_index = burst_index + 1)
            send_bits({8'h00, expected_burst_frame(burst_index)}, 48);
        burst_active = 1'b0;
        if (burst_seen != 64 || received != 69)
            $fatal(1, "64-event burst lost/duplicated frames seen=%0d total=%0d",
                   burst_seen, received);
        send_bits({8'h00, 48'h02_00_3C_00_00_00}, 40);
        if (received != 69) $fatal(1, "short frame after burst accepted");
        send_bits({8'h00, 48'h01_00_3C_55_00_00}, 48);
        if (received != 70 || event_type != 8'h01 || route != 8'h00 ||
            midi_parameter != 8'h3C || value != 8'h55)
            $fatal(1, "receiver did not recover after malformed frame");
        $display("PASS: five individual frames, 64 ordered burst frames, READY, malformed frames and recovery");
        $finish;
    end
endmodule
