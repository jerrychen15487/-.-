`timescale 1ns/1ps

// Production-rate digital latency vector.
//
// This testbench keeps the clock and SPI rate used by top.v, but removes the
// video/SD blocks so that the audio path can be tested quickly and repeatably:
// SPI MIDI RX -> four voices (including piano32 and optional additive32)/mixer ->
// optional echo -> PT8211 serial transmitter.
// The reported endpoint is the first complete non-zero 16-bit word observed
// at PT8211 DIN. It is deliberately a digital endpoint; it does not include
// the PT8211 analogue settling time or the ESP32/USB/key-scan time before CS.
module tb_audio_latency;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz system clock

    reg spi_sclk_i = 1'b0;
    reg spi_mosi_i = 1'b0;
    reg spi_cs_n_i = 1'b1;
    wire spi_ready_o;
    wire frame_valid;
    wire [7:0] event_type;
    wire [7:0] route;
    wire [7:0] midi_parameter;
    wire [7:0] value;

    spi_midi_frame_rx u_spi (
        .clk(clk), .rst_n(rst_n),
        .spi_sclk_i(spi_sclk_i), .spi_mosi_i(spi_mosi_i),
        .spi_cs_n_i(spi_cs_n_i), .spi_ready_o(spi_ready_o),
        .frame_valid(frame_valid), .event_type(event_type),
        .route(route), .midi_parameter(midi_parameter), .value(value)
    );

    reg [9:0] sample_counter = 10'd0;
    wire sample_tick = (sample_counter == 10'd1023);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample_counter <= 10'd0;
        else if (sample_tick)
            sample_counter <= 10'd0;
        else
            sample_counter <= sample_counter + 1'b1;
    end

    wire [6:0] note0, note1, note2, note3;
    wire [6:0] velocity0, velocity1, velocity2, velocity3;
    wire [3:0] gate;
    wire [3:0] retrigger;
    wire [3:0] voice_finished;
    wire signed [15:0] voice0_sample, voice0_basic_sample, spectral_sample;
    wire signed [15:0] voice1_sample, voice1_basic_sample;
    wire [31:0] voice0_phase;
    wire spectral_sample_valid, spectral_overrun;
    wire signed [15:0] voice2_sample, voice3_sample;
    wire signed [15:0] voice2_basic_sample, voice3_basic_sample;
    wire [7:0] envelope0, envelope1, envelope2, envelope3;
    wire [31:0] step0, step1, step2, step3;
    wire [63:0] piano32_samples;
    wire piano32_sample_valid, piano32_overrun;
    reg [1:0] program_select = 2'd0;
    wire timbre_select = (program_select != 2'd0);
    wire spectral_active = (program_select == 2'd2) && (note0 <= 7'd76);
    wire piano32_active = (program_select == 2'd0);
    reg echo_enable = 1'b0;

    poly_voice_ctrl u_voice_ctrl (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
        .event_type(event_type), .data1(midi_parameter), .data2(value),
        .voice_finished(voice_finished),
        .note0(note0), .note1(note1), .note2(note2), .note3(note3),
        .velocity0(velocity0), .velocity1(velocity1),
        .velocity2(velocity2), .velocity3(velocity3),
        .gate(gate), .retrigger(retrigger)
    );

    basic_dds_synth u_voice0 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note(note0), .velocity(velocity0), .gate(gate[0]),
        .retrigger(retrigger[0]), .timbre_select(timbre_select),
        .bend_factor_q14(16'd16384), .audio_sample(voice0_basic_sample),
        .envelope_level(envelope0), .voice_finished(voice_finished[0]),
        .phase_out(voice0_phase), .phase_step_out(step0)
    );
    additive32_synth u_additive32 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .enable(spectral_active), .phase(voice0_phase),
        .envelope(envelope0), .velocity(velocity0),
        .audio_sample(spectral_sample),
        .sample_valid(spectral_sample_valid), .overrun(spectral_overrun)
    );
    piano32_poly_synth u_piano32 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .enable(piano32_active),
        .step_bus({step3, step2, step1, step0}),
        .retrigger_bus(retrigger),
        .envelope_bus({envelope3, envelope2, envelope1, envelope0}),
        .velocity_bus({velocity3, velocity2, velocity1, velocity0}),
        .note_bus({note3, note2, note1, note0}),
        .sample0(piano32_samples[15:0]), .sample1(piano32_samples[31:16]),
        .sample2(piano32_samples[47:32]), .sample3(piano32_samples[63:48]),
        .sample_valid(piano32_sample_valid), .overrun(piano32_overrun)
    );
    assign voice0_sample = piano32_active ? piano32_samples[15:0] :
                           spectral_active ? spectral_sample : voice0_basic_sample;
    basic_dds_synth u_voice1 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note(note1), .velocity(velocity1), .gate(gate[1]),
        .retrigger(retrigger[1]), .timbre_select(timbre_select),
        .bend_factor_q14(16'd16384), .audio_sample(voice1_basic_sample),
        .envelope_level(envelope1), .voice_finished(voice_finished[1]),
        .phase_step_out(step1)
    );
    basic_dds_synth u_voice2 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note(note2), .velocity(velocity2), .gate(gate[2]),
        .retrigger(retrigger[2]), .timbre_select(timbre_select),
        .bend_factor_q14(16'd16384), .audio_sample(voice2_basic_sample),
        .envelope_level(envelope2), .voice_finished(voice_finished[2]),
        .phase_step_out(step2)
    );
    basic_dds_synth u_voice3 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note(note3), .velocity(velocity3), .gate(gate[3]),
        .retrigger(retrigger[3]), .timbre_select(timbre_select),
        .bend_factor_q14(16'd16384), .audio_sample(voice3_basic_sample),
        .envelope_level(envelope3), .voice_finished(voice_finished[3]),
        .phase_step_out(step3)
    );
    assign voice1_sample = piano32_active ? piano32_samples[31:16] : voice1_basic_sample;
    assign voice2_sample = piano32_active ? piano32_samples[47:32] : voice2_basic_sample;
    assign voice3_sample = piano32_active ? piano32_samples[63:48] : voice3_basic_sample;

    wire signed [17:0] mix_sum =
        {{2{voice0_sample[15]}}, voice0_sample} +
        {{2{voice1_sample[15]}}, voice1_sample} +
        {{2{voice2_sample[15]}}, voice2_sample} +
        {{2{voice3_sample[15]}}, voice3_sample};
    wire signed [15:0] audio_sample = mix_sum >>> 2;
    wire signed [15:0] audio_effected;
    // Match the production effecter placement while measuring the dry path.
    echo_delay u_echo (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .enable(echo_enable), .dry_in(audio_sample), .audio_out(audio_effected)
    );

    wire HP_BCK, HP_WS, HP_DIN;
    pt8211_tx u_pt8211 (
        .clk(clk), .rst_n(rst_n),
        .sample_left(audio_effected), .sample_right(audio_effected),
        .bck(HP_BCK), .ws(HP_WS), .din(HP_DIN)
    );

    integer cs_start_ns;
    integer frame_valid_ns;
    integer frame_sample_counter;
    integer first_word_ns;
    integer measuring;
    integer word_found;
    integer spectral_valid_count;
    integer piano32_valid_count;
    reg decoder_ws;
    reg decoder_seen_ws;
    reg decoder_aligned;
    reg [4:0] decoder_bits;
    reg [15:0] decoder_shift;
    reg [15:0] decoder_word;

    // Capture the request origin at the same digital boundary available to
    // GAO: the falling edge of the external CS input (before RX synchronizers).
    // PT8211 decoder waits for a WS boundary, then accepts complete words.
    always @(negedge spi_cs_n_i) begin
        if (rst_n) begin
            cs_start_ns = $time;
            frame_valid_ns = 0;
            first_word_ns = 0;
            measuring = 1;
            word_found = 0;
            decoder_seen_ws = 0;
            decoder_aligned = 0;
            decoder_bits = 0;
            decoder_shift = 0;
            spectral_valid_count = 0;
            piano32_valid_count = 0;
        end
    end

    always @(posedge spectral_sample_valid) begin
        if (measuring) spectral_valid_count = spectral_valid_count + 1;
    end
    always @(posedge piano32_sample_valid) begin
        if (measuring) piano32_valid_count = piano32_valid_count + 1;
    end

    always @(posedge frame_valid) begin
        if (measuring && (frame_valid_ns == 0)) begin
            frame_valid_ns = $time;
            frame_sample_counter = sample_counter;
        end
    end

    // PT8211 changes DIN/WS on BCK falling edges, so the rising edge is the
    // sampling edge. The complete word is assembled with the current DIN bit.
    always @(posedge HP_BCK) begin
        if (measuring && (HP_WS === 1'b0 || HP_WS === 1'b1)) begin
            if (!decoder_seen_ws) begin
                decoder_seen_ws = 1;
                decoder_ws = HP_WS;
                decoder_bits = 0;
                decoder_shift = 0;
            end else if (HP_WS != decoder_ws) begin
                decoder_aligned = 1;
                decoder_ws = HP_WS;
                // This edge is already the first bit of the new channel.
                decoder_bits = 1;
                decoder_shift = {15'd0, HP_DIN};
            end else if (decoder_aligned && decoder_bits == 5'd15) begin
                decoder_word = {decoder_shift[14:0], HP_DIN};
                if ((^decoder_word) === 1'bx)
                    $fatal(1, "unknown bit in complete PT8211 word");
                if ((!decoder_ws && (decoder_word !== u_pt8211.right_latched)) ||
                    (decoder_ws && (decoder_word !== u_pt8211.left_latched)))
                    $fatal(1, "PT8211 serial decoder mismatch ws=%b decoded=%h expected_left=%h expected_right=%h",
                           decoder_ws, decoder_word,
                           u_pt8211.left_latched, u_pt8211.right_latched);
                if (!word_found && (decoder_word != 16'h0000)) begin
                    if (frame_valid_ns == 0)
                        $fatal(1, "audio arrived before the input event");
                    first_word_ns = $time;
                    word_found = 1;
                end
                decoder_bits = 0;
                decoder_shift = 0;
            end else if (decoder_aligned) begin
                decoder_shift = {decoder_shift[14:0], HP_DIN};
                decoder_bits = decoder_bits + 1'b1;
            end
        end
    end

    task send_midi;
        input [7:0] event_code;
        input [7:0] parameter_byte;
        input [7:0] value_byte;
        reg [47:0] payload;
        integer i;
        begin
            if (spi_ready_o !== 1'b1) $fatal(1, "SPI not ready");
            payload = {event_code, 8'h00, parameter_byte, value_byte, 16'h0000};
            spi_cs_n_i = 1'b0;
            #100;
            for (i = 47; i >= 0; i = i - 1) begin
                spi_mosi_i = payload[i];
                #50 spi_sclk_i = 1'b1;
                #50 spi_sclk_i = 1'b0;
            end
            #100 spi_cs_n_i = 1'b1;
            #200;
        end
    endtask

    task reset_trial;
        input [1:0] program_value;
        input echo_value;
        input integer phase_delay_cycles;
        begin
            measuring = 0;
            spi_cs_n_i = 1'b1;
            spi_sclk_i = 1'b0;
            spi_mosi_i = 1'b0;
            program_select = program_value;
            echo_enable = echo_value;
            rst_n = 1'b0;
            repeat (10) @(negedge clk);
            rst_n = 1'b1;
            repeat (2048 + phase_delay_cycles) @(negedge clk);
            #3; // Keep stimulus away from clock edges.
        end
    endtask

    task check_one_note;
        input [6:0] note_value;
        input [6:0] velocity_value;
        input [1:0] program_value;
        input echo_value;
        input integer phase_delay_cycles;
        begin
            reset_trial(program_value, echo_value, phase_delay_cycles);
            if (audio_sample !== 16'sd0 || audio_effected !== 16'sd0)
                $fatal(1, "latency trial must start from digital silence (dry=%d out=%d)", audio_sample, audio_effected);
            send_midi(8'h01, {1'b0, note_value}, {1'b0, velocity_value});
            // 400 us covers several audio frames and the PT8211 word boundary.
            #400000;
            if (frame_valid_ns == 0)
                $fatal(1, "no frame_valid observed for note %0d", note_value);
            if (first_word_ns == 0)
                $fatal(1, "no non-zero PT8211 word observed for note %0d", note_value);
            if ((first_word_ns - cs_start_ns) >= 400000)
                $fatal(1, "digital latency exceeded the 400 us regression bound");
            if (spectral_overrun)
                $fatal(1, "additive32 engine overran the sample frame");
            if (piano32_overrun)
                $fatal(1, "piano32 engine overran the sample frame");
            if ((program_value == 2'd0) && (piano32_valid_count == 0))
                $fatal(1, "piano32 engine did not produce a sample");
            if ((program_value == 2'd2) && (note_value <= 7'd76) &&
                (spectral_valid_count == 0))
                $fatal(1, "additive32 engine did not produce a sample");
            $display("VECTOR note=%0d velocity=%0d program=%0d echo=%0d frame_sample_counter=%0d CS->frame=%0d ns, CS->first_nonzero_PT8211_word=%0d ns",
                     note_value, velocity_value, program_value, echo_value,
                     frame_sample_counter,
                     frame_valid_ns - cs_start_ns,
                     first_word_ns - cs_start_ns);
            send_midi(8'h02, {1'b0, note_value}, 8'h00);
            #100000;
        end
    endtask

    initial begin
        if ($test$plusargs("VCD")) begin
            $dumpfile("sim/audio_latency.vcd");
            $dumpvars(1, tb_audio_latency);
        end
        measuring = 0;
        word_found = 0;
        decoder_seen_ws = 0;
        check_one_note(7'd60, 7'd100, 2'd0, 1'b0, 0);   // piano, echo off
        check_one_note(7'd60, 7'd100, 2'd0, 1'b1, 740); // piano, echo on, varied phase
        check_one_note(7'd60, 7'd100, 2'd1, 1'b0, 770); // organ, echo off, varied phase
        check_one_note(7'd72, 7'd100, 2'd0, 1'b0, 350); // higher piano note
        check_one_note(7'd60, 7'd100, 2'd2, 1'b0, 510); // 32-partial additive C4
        check_one_note(7'd76, 7'd100, 2'd2, 1'b0, 900); // highest additive note
        check_one_note(7'd77, 7'd100, 2'd2, 1'b0, 320); // organ fallback above limit

        reset_trial(2'd0, 1'b0, 0);
        send_midi(8'h01, 8'd60, 8'd100);
        send_midi(8'h01, 8'd64, 8'd100);
        send_midi(8'h01, 8'd67, 8'd100);
        send_midi(8'h01, 8'd72, 8'd100);
        #100000;
        if (gate !== 4'b1111)
            $fatal(1, "four-note vector did not activate all voices, gate=%b", gate);
        $display("VECTOR four_note_chord gate=%b PASS", gate);
        send_midi(8'h03, 8'd123, 8'd0);       // All Notes Off
        #100000;

        measuring = 0;
        $display("PASS audio latency vectors: isolated trials, varied sample phase, piano dry/wet, organ, additive32, high-note fallback and four-note chord");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "global test timeout");
    end
endmodule
