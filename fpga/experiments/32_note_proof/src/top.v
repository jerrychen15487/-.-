module top (
    input  wire sys_clk,
    input  wire sys_rst_n,
    input  wire view_key_n,
    input  wire spectrum_key_n,
    input  wire uart_rx_i,
    input  wire score_uart_rx_i,
    output wire score_uart_tx_o,
    input  wire sd_miso,
    output wire sd_cs_n,
    output wire sd_sck,
    output wire sd_mosi,
    input  wire spi_sclk_i,
    input  wire spi_mosi_i,
    input  wire spi_cs_n_i,
    output wire spi_ready_o,
    output wire HP_BCK,
    output wire HP_WS,
    output wire HP_DIN,
    output wire PCM_BCK,
    output wire PCM_WS,
    output wire PCM_DIN,
    output wire PA_EN,
    output wire debug_gate,
    output wire [2:0] tmds_d_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire       tmds_clk_p_0,
    output wire       tmds_clk_n_0
);
    // The two standalone audio self-tests proved that an internal power-on
    // reset gives deterministic startup.  AA13 is KEY0 on the official NEO
    // Dock constraints (active low), so keep it as a manual reset input and
    // also hold the whole design in reset for 1024 clocks after configuration.
    reg [9:0] por_count = 10'd0;
    wire por_done = &por_count;
    wire core_rst_n = sys_rst_n && por_done;
    wire spectrum_test_active;
    wire echo_enabled;
    spectrum_mode_key u_spectrum_mode_key (
        .clk(sys_clk), .rst_n(core_rst_n), .key_n(spectrum_key_n),
        .test_mode(spectrum_test_active), .echo_enabled(echo_enabled)
    );
    reg spectrum_test_previous;
    always @(posedge sys_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            spectrum_test_previous <= 1'b0;
        else
            spectrum_test_previous <= spectrum_test_active;
    end
    // Flush only the audio/visualized-note path at a mode boundary. The SD
    // store and its BLE/UART transactions stay alive while the demo runs.
    wire voice_rst_n = core_rst_n &&
                       (spectrum_test_previous == spectrum_test_active);

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            por_count <= 10'd0;
        else if (!por_done)
            por_count <= por_count + 1'b1;
    end

    reg [9:0] sample_counter;
    wire sample_tick = (sample_counter == 10'd1023);

    wire [7:0] uart_data;
    wire uart_valid;
    wire uart_framing_error;
    wire frame_valid;
    wire legacy_frame_valid;
    wire spi_frame_valid;
    wire crc_error;
    wire [7:0] sequence;
    wire [7:0] event_type;
    wire [7:0] channel;
    wire [7:0] data1;
    wire [7:0] data2;
    wire [7:0] legacy_event_type, legacy_channel, legacy_data1, legacy_data2;
    wire [7:0] spi_event_type, spi_route, spi_parameter, spi_value;
    // The existing UART self-test remains available on J9 pin 11. In the
    // unlikely case of simultaneous frames the new real-time SPI event wins.
    wire test_frame_valid;
    wire [7:0] test_event_type, test_data1, test_data2;
    spectrum_test_pattern u_pattern (
        .clk(sys_clk), .rst_n(voice_rst_n && spectrum_test_active),
        .sample_tick(sample_tick),
        .frame_valid(test_frame_valid), .event_type(test_event_type),
        .data1(test_data1), .data2(test_data2)
    );
    assign frame_valid = voice_rst_n &&
                         (spectrum_test_active ? test_frame_valid :
                         (spi_frame_valid | legacy_frame_valid));
    assign event_type = spectrum_test_active ? test_event_type :
                        (spi_frame_valid ? spi_event_type : legacy_event_type);
    assign channel = spectrum_test_active ? 8'd0 :
                     (spi_frame_valid ? spi_route : legacy_channel);
    assign data1 = spectrum_test_active ? test_data1 :
                   (spi_frame_valid ? spi_parameter : legacy_data1);
    assign data2 = spectrum_test_active ? test_data2 :
                   (spi_frame_valid ? spi_value : legacy_data2);
    wire [6:0] note0, note1, note2, note3;
    wire [6:0] velocity0, velocity1, velocity2, velocity3;
    wire [3:0] gate;
    wire [3:0] retrigger;
    wire [3:0] voice_finished;
    reg timbre_select;
    reg [1:0] program_select;
    reg [13:0] pitch_bend;
    reg [6:0] vibrato_depth;
    reg [31:0] vibrato_phase;
    reg signed [8:0] vibrato_wave_q;
    reg [6:0] vibrato_depth_q;
    reg [13:0] pitch_bend_q1, pitch_bend_q2;
    reg signed [16:0] vibrato_product_q;
    reg [13:0] effective_pitch_bend_q;
    reg [15:0] bend_factor_q14;
    reg [15:0] bend_factor_low_q, bend_factor_low_q2;
    reg [8:0] bend_factor_delta_q;
    reg [9:0] bend_fraction_q;
    reg [19:0] bend_fraction_product_q;
    // Pipeline the expression controller in matched phase/depth/bend pairs.
    // The extra two clocks are 40 ns at 50 MHz, far below one audio sample.
    // At CC1=127 the triangular LFO spans about +/-0.5 semitone. Pitch bend
    // itself remains the conventional +/-2 semitone range.
    wire signed [16:0] vibrato_offset = vibrato_product_q >>> 3;
    wire signed [17:0] pitch_with_vibrato =
        $signed({1'b0, pitch_bend_q2}) + vibrato_offset;
    wire [13:0] effective_pitch_bend_next =
        (pitch_with_vibrato < 18'sd0) ? 14'd0 :
        (pitch_with_vibrato > 18'sd16383) ? 14'd16383 :
        pitch_with_vibrato[13:0];
    // Keep lookup/delta, interpolation multiply, and final sum in separate
    // register stages. The added 40 ns control latency is negligible beside
    // the audio sample period; all interpolator operands remain aligned.
    wire [4:0] bend_segment = {1'b0, effective_pitch_bend_q[13:10]};
    wire [15:0] bend_factor_low = bend_factor_endpoint(bend_segment);
    wire [15:0] bend_factor_high = bend_factor_endpoint(bend_segment + 5'd1);
    wire [15:0] bend_factor_delta_wide =
        bend_factor_high - bend_factor_low;
    wire [8:0] bend_factor_delta = bend_factor_delta_wide[8:0];
    wire [19:0] bend_fraction_product =
        bend_factor_delta_q * bend_fraction_q + 20'd512;
    wire [16:0] bend_factor_sum =
        {1'b0, bend_factor_low_q2} +
        {7'd0, bend_fraction_product_q[19:10]};

    // 17 quarter-semitone endpoints cover the conventional +/-2 semitone
    // bend range. Interpolation is shared by all four voices; the current
    // voices keep their phase, so pitch changes do not retrigger a note.
    function [15:0] bend_factor_endpoint;
        input [4:0] index;
        begin
            case (index)
                5'd0: bend_factor_endpoint = 16'd14596;
                5'd1: bend_factor_endpoint = 16'd14809;
                5'd2: bend_factor_endpoint = 16'd15024;
                5'd3: bend_factor_endpoint = 16'd15243;
                5'd4: bend_factor_endpoint = 16'd15464;
                5'd5: bend_factor_endpoint = 16'd15689;
                5'd6: bend_factor_endpoint = 16'd15918;
                5'd7: bend_factor_endpoint = 16'd16149;
                5'd8: bend_factor_endpoint = 16'd16384;
                5'd9: bend_factor_endpoint = 16'd16622;
                5'd10: bend_factor_endpoint = 16'd16864;
                5'd11: bend_factor_endpoint = 16'd17109;
                5'd12: bend_factor_endpoint = 16'd17358;
                5'd13: bend_factor_endpoint = 16'd17611;
                5'd14: bend_factor_endpoint = 16'd17867;
                5'd15: bend_factor_endpoint = 16'd18127;
                5'd16: bend_factor_endpoint = 16'd18390;
                default: bend_factor_endpoint = 16'd16384;
            endcase
        end
    endfunction

    // Four linear quarters form a smooth triangle with no discontinuity.
    // Updating the phase at 48.828125 kHz gives a 5 Hz musical vibrato.
    function signed [8:0] vibrato_triangle;
        input [31:0] phase_value;
        reg [6:0] ramp;
        begin
            ramp = phase_value[29:23];
            case (phase_value[31:30])
                2'b00: vibrato_triangle =  $signed({2'b00, ramp});
                2'b01: vibrato_triangle =  $signed({2'b00, ~ramp});
                2'b10: vibrato_triangle = -$signed({2'b00, ramp});
                default: vibrato_triangle = -$signed({2'b00, ~ramp});
            endcase
        end
    endfunction
    wire signed [15:0] voice0_sample, voice0_basic_sample;
    wire signed [15:0] spectral_sample, voice1_sample, voice1_basic_sample;
    wire signed [15:0] voice2_sample, voice3_sample;
    wire signed [15:0] voice2_basic_sample, voice3_basic_sample;
    wire [7:0] envelope0, envelope1, envelope2, envelope3;
    wire [31:0] voice0_phase;
    wire [31:0] step0, step1, step2, step3;
    wire [63:0] piano32_samples;
    wire piano32_sample_valid, piano32_overrun;
    wire piano32_active = (program_select == 2'd0) && !spectrum_test_active;
    wire spectral_sample_valid, spectral_overrun;
    wire spectral_active = (program_select == 2'd2) &&
                           (note0 <= 7'd76) && !spectrum_test_active;
    additive32_synth u_additive32_synth (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .enable(spectral_active), .phase(voice0_phase),
        .envelope(envelope0), .velocity(velocity0),
        .audio_sample(spectral_sample),
        .sample_valid(spectral_sample_valid), .overrun(spectral_overrun)
    );
    piano32_poly_synth u_piano32_poly_synth (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .enable(piano32_active),
        .step_bus({step3, step2, step1, step0}),
        .retrigger_bus(retrigger),
        .envelope_bus({envelope3, envelope2, envelope1, envelope0}),
        .velocity_bus({velocity3, velocity2, velocity1, velocity0}),
        .note_bus({note3, note2, note1, note0}),
        .sample0(piano32_samples[15:0]),
        .sample1(piano32_samples[31:16]),
        .sample2(piano32_samples[47:32]),
        .sample3(piano32_samples[63:48]),
        .sample_valid(piano32_sample_valid), .overrun(piano32_overrun)
    );
    assign voice0_sample = piano32_active ? piano32_samples[15:0] :
                           spectral_active ? spectral_sample : voice0_basic_sample;
    assign voice1_sample = piano32_active ? piano32_samples[31:16] : voice1_basic_sample;
    assign voice2_sample = piano32_active ? piano32_samples[47:32] : voice2_basic_sample;
    assign voice3_sample = piano32_active ? piano32_samples[63:48] : voice3_basic_sample;
    wire signed [17:0] mix_sum =
        {{2{voice0_sample[15]}}, voice0_sample} +
        {{2{voice1_sample[15]}}, voice1_sample} +
        {{2{voice2_sample[15]}}, voice2_sample} +
        {{2{voice3_sample[15]}}, voice3_sample};
    // Divide by four so four full-scale voices cannot clip the 16-bit DAC.
    wire signed [15:0] poly32_sample;
    wire poly32_sample_valid;
    wire [5:0] poly32_active_count;
    // Program 3 is a separate 32-note lightweight mode. Existing P/O/A
    // modes remain unchanged; 32 partials per piano note is not 32-note polyphony.
    poly32_light_synth u_poly32_light_synth (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .frame_valid(frame_valid), .event_type(event_type),
        .data1(data1), .data2(data2),
        .bend_factor_q14(bend_factor_q14),
        .audio_sample(poly32_sample), .sample_valid(poly32_sample_valid),
        .active_count(poly32_active_count)
    );
    wire signed [15:0] audio_sample =
        (program_select == 2'd3) ? poly32_sample : (mix_sum >>> 2);
    wire signed [15:0] audio_effected;
    echo_delay u_echo_delay (
        .clk(sys_clk), .rst_n(voice_rst_n),
        .sample_tick(sample_tick),
        .enable(echo_enabled && !spectrum_test_active),
        .dry_in(audio_sample), .audio_out(audio_effected)
    );
    // The spectrum represents the complete mix, but an oscilloscope trace of
    // several unrelated notes is inherently dense.  Show the loudest active
    // voice in the upper panel so the waveform is stable and reveals the
    // selected synthesis method even while a chord is held.
    wire pair01_choose_1 = envelope1 > envelope0;
    wire pair23_choose_3 = envelope3 > envelope2;
    wire [7:0] pair01_envelope = pair01_choose_1 ? envelope1 : envelope0;
    wire [7:0] pair23_envelope = pair23_choose_3 ? envelope3 : envelope2;
    wire signed [15:0] pair01_sample = pair01_choose_1 ? voice1_sample : voice0_sample;
    wire signed [15:0] pair23_sample = pair23_choose_3 ? voice3_sample : voice2_sample;
    reg [7:0] pair01_envelope_q,pair23_envelope_q;
    reg signed [15:0] pair01_sample_q,pair23_sample_q;
    wire signed [15:0] primary_voice_sample =
        (pair23_envelope_q > pair01_envelope_q) ?
        pair23_sample_q : pair01_sample_q;
    always @(posedge sys_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            pair01_envelope_q <= 0;
            pair23_envelope_q <= 0;
            pair01_sample_q <= 0;
            pair23_sample_q <= 0;
        end else begin
            pair01_envelope_q <= pair01_envelope;
            pair23_envelope_q <= pair23_envelope;
            pair01_sample_q <= pair01_sample;
            pair23_sample_q <= pair23_sample;
        end
    end
    // Coherent audio/timbre display snapshot. Values remain stable until the
    // pixel domain observes the synchronized toggle.
    reg sample_toggle;
    reg signed [15:0] visual_audio_snapshot;
    reg visual_timbre;
    reg [1:0] visual_program;
    reg visual_additive_active;
    reg [7:0] visual_additive_level;
    wire [14:0] additive_level_product = envelope0 * velocity0;

    // Program 0=piano, 1=organ, 2=single-note 32-partial additive proof.
    // Other nonzero programs retain the previous organ behavior.
    always @(posedge sys_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            timbre_select <= 1'b0;
            program_select <= 2'd0;
        end else if (!voice_rst_n) begin
            timbre_select <= spectrum_test_active;
            program_select <= spectrum_test_active ? 2'd1 : 2'd0;
        end else if (frame_valid && (event_type == 8'h05)) begin
            timbre_select <= (data1 != 8'd0);
            program_select <= (data1 == 8'd3) ? 2'd3 :
                              (data1 == 8'd2) ? 2'd2 :
                              (data1 == 8'd0) ? 2'd0 : 2'd1;
        end
    end

    always @(posedge sys_clk or negedge voice_rst_n) begin
        if (!voice_rst_n) begin
            pitch_bend <= 14'd8192;
            vibrato_depth <= 7'd0;
            vibrato_phase <= 32'd0;
            vibrato_wave_q <= 9'sd0;
            vibrato_depth_q <= 7'd0;
            pitch_bend_q1 <= 14'd8192;
            pitch_bend_q2 <= 14'd8192;
            vibrato_product_q <= 17'sd0;
            effective_pitch_bend_q <= 14'd8192;
            bend_factor_q14 <= 16'd16384;
            bend_factor_low_q <= 16'd16384;
            bend_factor_low_q2 <= 16'd16384;
            bend_factor_delta_q <= 9'd238;
            bend_fraction_q <= 10'd0;
            bend_fraction_product_q <= 20'd512;
        end else begin
            if (frame_valid && (event_type == 8'h04))
                pitch_bend <= {data2[6:0], data1[6:0]};
            if (frame_valid && (event_type == 8'h03) && (data1 == 8'd1))
                vibrato_depth <= data2[6:0];
            if (sample_tick)
                vibrato_phase <= vibrato_phase + 32'd439805;
            vibrato_wave_q <= vibrato_triangle(vibrato_phase);
            vibrato_depth_q <= vibrato_depth;
            pitch_bend_q1 <= pitch_bend;
            vibrato_product_q <= vibrato_wave_q *
                $signed({1'b0, vibrato_depth_q});
            pitch_bend_q2 <= pitch_bend_q1;
            effective_pitch_bend_q <= effective_pitch_bend_next;
            bend_factor_low_q <= bend_factor_low;
            bend_factor_delta_q <= bend_factor_delta;
            bend_fraction_q <= effective_pitch_bend_q[9:0];
            bend_factor_low_q2 <= bend_factor_low_q;
            bend_fraction_product_q <= bend_fraction_product;
            bend_factor_q14 <= bend_factor_sum[15:0];
        end
    end

    always @(posedge sys_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            sample_counter <= 10'd0;
            sample_toggle  <= 1'b0;
            visual_audio_snapshot <= 16'sd0;
            visual_timbre <= 1'b0;
            visual_program <= 2'd0;
            visual_additive_active <= 1'b0;
            visual_additive_level <= 8'd0;
        end else if (sample_tick) begin
            sample_counter <= 10'd0;
            sample_toggle  <= ~sample_toggle;
            visual_audio_snapshot <= (program_select == 2'd3) ?
                                     poly32_sample : primary_voice_sample;
            visual_timbre <= timbre_select;
            visual_program <= program_select;
            visual_additive_active <= spectral_active;
            visual_additive_level <= spectral_active ?
                                     additive_level_product[14:7] : 8'd0;
        end else begin
            sample_counter <= sample_counter + 1'b1;
        end
    end

    uart_rx #(.CLOCK_HZ(50_000_000), .BAUD(1_000_000)) u_uart_rx (
        .clk(sys_clk), .rst_n(core_rst_n), .rx(uart_rx_i),
        .data(uart_data), .valid(uart_valid), .framing_error(uart_framing_error)
    );

    // The library UART and SD card are independent of the real-time MIDI
    // SPI/audio path. The card is driven only with NEO Dock SW2 in EVB mode.
    wire score_storage_ready;
    wire [31:0] score_catalog_generation;
    wire preview_request;
    wire preview_done,preview_available,preview_note_valid;
    wire [31:0] preview_note_index,preview_start_tick,
        preview_duration_tick;
    wire [6:0] preview_pitch;
    wire [1:0] preview_part_mask;
    wire preview_score_onset;
    wire preview_score_hold,preview_score_velocity;
    wire [2:0] preview_dynamic;
    wire [15:0] preview_bpm;
    wire page_request,page_begin,page_done,page_available,page_byte_valid;
    wire [3:0] page_result;
    wire [1:0] page_notation;
    wire [5:0] page_index,page_selected_index;
    wire [15:0] page_request_token,page_completed_token;
    wire [15:0] page_byte_index;
    wire [7:0] page_byte;
    wire page_diag_err_valid,page_diag_err_page_found,
        page_diag_err_index_clear,page_diag_pub_valid;
    wire [2:0] page_diag_err_state;
    wire [31:0] page_diag_err_length,page_diag_err_offset,
        page_diag_err_total,page_diag_pub_length,
        page_diag_pub_byte_offset;
    wire [4:0] page_diag_pub_page_field;
    score_store_sd #(.MAX_SLOTS(1)) u_score_store_sd (
            .clk(sys_clk),.rst_n(core_rst_n),
            .uart_rx(score_uart_rx_i),.uart_tx(score_uart_tx_o),
            .sd_miso(sd_miso),.sd_cs_n(sd_cs_n),
            .sd_sck(sd_sck),.sd_mosi(sd_mosi),
            .storage_ready(score_storage_ready),
            .catalog_generation(score_catalog_generation),
            .preview_request(preview_request),.preview_done(preview_done),
            .preview_available(preview_available),
            .preview_note_valid(preview_note_valid),
            .preview_note_index(preview_note_index),
            .preview_start_tick(preview_start_tick),
            .preview_duration_tick(preview_duration_tick),
            .preview_pitch(preview_pitch),
            .preview_part_mask(preview_part_mask),
            .preview_score_onset(preview_score_onset),
            .preview_score_hold(preview_score_hold),
            .preview_score_velocity(preview_score_velocity),
            .preview_dynamic(preview_dynamic),
            .preview_bpm(preview_bpm),
            .page_request(page_request),.page_notation(page_notation),
            .page_index(page_index),
            .page_request_token(page_request_token),
            .page_completed_token(page_completed_token),
            .page_selected_index(page_selected_index),
            .page_begin(page_begin),.page_done(page_done),
            .page_available(page_available),.page_result(page_result),
            .page_byte_valid(page_byte_valid),
            .page_byte_index(page_byte_index),.page_byte(page_byte),
            .page_diag_err_valid(page_diag_err_valid),
            .page_diag_err_page_found(page_diag_err_page_found),
            .page_diag_err_index_clear(page_diag_err_index_clear),
            .page_diag_err_state(page_diag_err_state),
            .page_diag_err_length(page_diag_err_length),
            .page_diag_err_offset(page_diag_err_offset),
            .page_diag_err_total(page_diag_err_total),
            .page_diag_pub_valid(page_diag_pub_valid),
            .page_diag_pub_length(page_diag_pub_length),
            .page_diag_pub_byte_offset(page_diag_pub_byte_offset),
            .page_diag_pub_page_field(page_diag_pub_page_field)
    );

    midi_frame_rx u_frame_rx (
        .clk(sys_clk), .rst_n(core_rst_n), .rx_data(uart_data), .rx_valid(uart_valid),
        .frame_valid(legacy_frame_valid), .crc_error(crc_error), .sequence(sequence),
        .event_type(legacy_event_type), .channel(legacy_channel),
        .data1(legacy_data1), .data2(legacy_data2)
    );

    spi_midi_frame_rx u_spi_frame_rx (
        .clk(sys_clk), .rst_n(core_rst_n),
        .spi_sclk_i(spi_sclk_i), .spi_mosi_i(spi_mosi_i),
        .spi_cs_n_i(spi_cs_n_i), .spi_ready_o(spi_ready_o),
        .frame_valid(spi_frame_valid), .event_type(spi_event_type),
        .route(spi_route), .midi_parameter(spi_parameter), .value(spi_value)
    );

    poly_voice_ctrl u_voice_ctrl (
        .clk(sys_clk), .rst_n(voice_rst_n), .frame_valid(frame_valid),
        .event_type(event_type), .data1(data1), .data2(data2),
        .voice_finished(voice_finished),
        .note0(note0), .note1(note1), .note2(note2), .note3(note3),
        .velocity0(velocity0), .velocity1(velocity1),
        .velocity2(velocity2), .velocity3(velocity3),
        .gate(gate), .retrigger(retrigger)
    );

    basic_dds_synth u_voice0 (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .note(note0), .velocity(velocity0), .gate(gate[0]), .retrigger(retrigger[0]),
        .timbre_select(timbre_select),
        .bend_factor_q14(bend_factor_q14),
        .audio_sample(voice0_basic_sample), .envelope_level(envelope0),
        .voice_finished(voice_finished[0]), .phase_out(voice0_phase),
        .phase_step_out(step0)
    );

    basic_dds_synth u_voice1 (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .note(note1), .velocity(velocity1), .gate(gate[1]), .retrigger(retrigger[1]),
        .timbre_select(timbre_select),
        .bend_factor_q14(bend_factor_q14),
        .audio_sample(voice1_basic_sample), .envelope_level(envelope1),
        .voice_finished(voice_finished[1]), .phase_step_out(step1)
    );

    basic_dds_synth u_voice2 (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .note(note2), .velocity(velocity2), .gate(gate[2]), .retrigger(retrigger[2]),
        .timbre_select(timbre_select),
        .bend_factor_q14(bend_factor_q14),
        .audio_sample(voice2_basic_sample), .envelope_level(envelope2),
        .voice_finished(voice_finished[2]), .phase_step_out(step2)
    );

    basic_dds_synth u_voice3 (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .note(note3), .velocity(velocity3), .gate(gate[3]), .retrigger(retrigger[3]),
        .timbre_select(timbre_select),
        .bend_factor_q14(bend_factor_q14),
        .audio_sample(voice3_basic_sample), .envelope_level(envelope3),
        .voice_finished(voice_finished[3]), .phase_step_out(step3)
    );

    pt8211_tx u_dac_tx (
        .clk(sys_clk), .rst_n(core_rst_n),
        .sample_left(audio_effected), .sample_right(audio_effected),
        .bck(HP_BCK), .ws(HP_WS), .din(HP_DIN)
    );

    // Independent standard-I2S output on J8/PMOD1 for an external PCM5102A.
    // Keep the PT8211 path and PA_EN unchanged for immediate A/B comparison.
    pcm5102_i2s_tx u_pcm5102_tx (
        .clk(sys_clk), .rst_n(core_rst_n),
        .sample_left(audio_effected), .sample_right(audio_effected),
        .bck(PCM_BCK), .ws(PCM_WS), .din(PCM_DIN)
    );

    // NEO Dock schematic: PA_EN=0 means amplifier on.
    assign PA_EN     = 1'b0;
    assign debug_gate = (program_select == 2'd3) ?
                        (poly32_active_count != 0) : (|gate);

    wire [255:0] spectrum_magnitudes;
    wire spectrum_update_toggle;
    fft64_spectrum u_fft64_spectrum (
        .clk(sys_clk), .rst_n(voice_rst_n), .sample_tick(sample_tick),
        .audio_sample(audio_effected),
        .magnitude_bus(spectrum_magnitudes),
        .update_toggle(spectrum_update_toggle)
    );

    // DVI-compatible video on the NEO Dock HDMI connector.
    wire pixel_clk;
    wire serial_clk;
    wire video_pll_locked;
    wire video_async_rst_n = core_rst_n & video_pll_locked;
    video_pll u_video_pll (
        .clk_in(sys_clk), .reset(~core_rst_n),
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .locked(video_pll_locked)
    );

    // Asynchronous assertion, synchronous release in the pixel clock domain.
    (* ASYNC_REG = "TRUE" *) reg [1:0] video_reset_sync;
    always @(posedge pixel_clk or negedge video_async_rst_n) begin
        if (!video_async_rst_n)
            video_reset_sync <= 2'b00;
        else
            video_reset_sync <= {video_reset_sync[0], 1'b1};
    end
    wire video_rst_n = video_reset_sync[1];

    wire video_hsync, video_vsync, video_de;
    wire [9:0] video_x, video_y;
    video_timing_640x480 u_video_timing (
        .pixel_clk(pixel_clk), .rst_n(video_rst_n),
        .hsync(video_hsync), .vsync(video_vsync), .de(video_de),
        .pix_x(video_x), .pix_y(video_y)
    );
    wire [15:0] page_pixel_addr;
    wire [7:0] page_pixel_byte;
    wire page_ready_video;
    wire [23:0] sheet_rgb;
    score_page_cache u_score_page_cache (
        .sys_clk(sys_clk),.sys_rst_n(core_rst_n),
        .begin_load(page_begin || page_request),
        .byte_valid(page_byte_valid),.read_done(page_done),
        .read_available(page_available),
        .byte_index(page_byte_index),.byte_value(page_byte),
        .pixel_clk(pixel_clk),.pixel_rst_n(video_rst_n),
        .pixel_byte_addr(page_pixel_addr),
        .pixel_byte(page_pixel_byte),.ready_video(page_ready_video)
    );
    score_page_video u_score_page_video (
        .pixel_clk(pixel_clk),.pixel_rst_n(video_rst_n),
        .de(video_de),.pix_x(video_x),.pix_y(video_y),
        .page_ready(page_ready_video),.page_byte(page_pixel_byte),
        .page_addr(page_pixel_addr),.rgb(sheet_rgb)
    );

    // Pausing freezes only the piano-roll preview; audio, SPI/READY and score
    // UART continue to run in either display mode.
    wire piano_demo_mode,sheet_mode,preview_paused_sys;
    view_key_control u_view_key_control (
        .clk(sys_clk),.rst_n(core_rst_n),.key_n(view_key_n),
        .piano_demo_mode(piano_demo_mode),
        .preview_paused(preview_paused_sys),
        .preview_request(preview_request),
        .sheet_mode(sheet_mode),.page_request(page_request),
        .page_notation(page_notation),.page_index(page_index),
        .page_done(page_done),.page_available(page_available),
        .page_selected_index(page_selected_index),
        .page_request_token(page_request_token),
        .page_completed_token(page_completed_token)
    );
    // Persistent page diagnostics. The system-clock pulses are too short to
    // sample directly in the pixel domain, so retain the last reached stage.
    // This also makes an absent/unsupported page visibly different from a
    // video-path failure without touching the SD card contents.
    reg [3:0] page_stage_sys;
    always @(posedge sys_clk or negedge core_rst_n) begin
        if(!core_rst_n) page_stage_sys<=4'd0;
        else if(page_done) page_stage_sys<=page_result;
        else if(page_begin) page_stage_sys<=4'd2;
        else if(page_request) page_stage_sys<=4'd1;
    end
    (* ASYNC_REG = "TRUE" *) reg [3:0] page_stage_video_meta;
    (* ASYNC_REG = "TRUE" *) reg [3:0] page_stage_video_sync;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            page_stage_video_meta<=0;
            page_stage_video_sync<=0;
        end else begin
            page_stage_video_meta<=page_stage_sys;
            page_stage_video_sync<=page_stage_video_meta;
        end
    end
    // Diagnostic snapshots are write-once in sys_clk until reset. After the
    // valid flags cross the pixel clock, the data buses have ample settling
    // time; a photo of the grid below then belongs to one failure only.
    reg [1:0] page_diag_valid_video, page_pub_valid_video;
    reg [31:0] page_diag_length_video_1,page_diag_length_video_2;
    reg [31:0] page_diag_offset_video_1,page_diag_offset_video_2;
    reg [31:0] page_diag_total_video_1,page_diag_total_video_2;
    reg [31:0] page_pub_length_video_1,page_pub_length_video_2;
    reg [31:0] page_pub_offset_video_1,page_pub_offset_video_2;
    reg [2:0] page_diag_state_video_1,page_diag_state_video_2;
    reg [4:0] page_pub_field_video_1,page_pub_field_video_2;
    reg [1:0] page_diag_found_video,page_diag_clear_video;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            page_diag_valid_video<=0;page_pub_valid_video<=0;
            page_diag_found_video<=0;page_diag_clear_video<=0;
            page_diag_length_video_1<=0;page_diag_length_video_2<=0;
            page_diag_offset_video_1<=0;page_diag_offset_video_2<=0;
            page_diag_total_video_1<=0;page_diag_total_video_2<=0;
            page_pub_length_video_1<=0;page_pub_length_video_2<=0;
            page_pub_offset_video_1<=0;page_pub_offset_video_2<=0;
            page_diag_state_video_1<=0;page_diag_state_video_2<=0;
            page_pub_field_video_1<=0;page_pub_field_video_2<=0;
        end else begin
            page_diag_valid_video<={page_diag_valid_video[0],page_diag_err_valid};
            page_pub_valid_video<={page_pub_valid_video[0],page_diag_pub_valid};
            page_diag_found_video<={page_diag_found_video[0],page_diag_err_page_found};
            page_diag_clear_video<={page_diag_clear_video[0],page_diag_err_index_clear};
            page_diag_length_video_1<=page_diag_err_length;
            page_diag_length_video_2<=page_diag_length_video_1;
            page_diag_offset_video_1<=page_diag_err_offset;
            page_diag_offset_video_2<=page_diag_offset_video_1;
            page_diag_total_video_1<=page_diag_err_total;
            page_diag_total_video_2<=page_diag_total_video_1;
            page_pub_length_video_1<=page_diag_pub_length;
            page_pub_length_video_2<=page_pub_length_video_1;
            page_pub_offset_video_1<=page_diag_pub_byte_offset;
            page_pub_offset_video_2<=page_pub_offset_video_1;
            page_diag_state_video_1<=page_diag_err_state;
            page_diag_state_video_2<=page_diag_state_video_1;
            page_pub_field_video_1<=page_diag_pub_page_field;
            page_pub_field_video_2<=page_pub_field_video_1;
        end
    end
    // Version D1A61018 (diagnostic format 1, 2026-10-18). Eight rows,
    // MSB left, 16x32 pixels per bit. Rows 2..8: flags, published length,
    // publication file offset, observed length, bitmap offset, total bytes,
    // expected length. Photograph the whole grid without changing songs.
    reg [31:0] page_diag_word;
    always @* begin
        case(video_y[8:5])
            4'd1:page_diag_word=32'hD1A61019;
            4'd2:page_diag_word={page_diag_valid_video[1],
                page_pub_valid_video[1],page_diag_found_video[1],
                page_diag_clear_video[1],page_diag_state_video_2,
                page_pub_field_video_2,20'd0};
            4'd3:page_diag_word=page_pub_length_video_2;
            4'd4:page_diag_word=page_pub_offset_video_2;
            4'd5:page_diag_word=page_diag_length_video_2;
            4'd6:page_diag_word=page_diag_offset_video_2;
            4'd7:page_diag_word=page_diag_total_video_2;
            4'd8:page_diag_word=32'd57600;
            default:page_diag_word=0;
        endcase
    end
    (* ASYNC_REG = "TRUE" *) reg [1:0] demo_mode_video_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sheet_mode_video_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] paused_video_sync;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            demo_mode_video_sync <= 2'b00;
            sheet_mode_video_sync <= 2'b00;
            paused_video_sync <= 2'b00;
        end else begin
            demo_mode_video_sync <= {demo_mode_video_sync[0], piano_demo_mode};
            sheet_mode_video_sync <= {sheet_mode_video_sync[0], sheet_mode};
            paused_video_sync <= {paused_video_sync[0], preview_paused_sys};
        end
    end

    wire [23:0] visualizer_rgb;
    midi_visualizer u_visualizer (
        .pixel_clk(pixel_clk), .rst_n(video_rst_n), .de(video_de),
        .pix_x(video_x), .pix_y(video_y),
        .audio_snapshot_async(visual_audio_snapshot),
        .snapshot_toggle_async(sample_toggle),
        .timbre_snapshot_async(visual_timbre),
        .program_snapshot_async(visual_program),
        .additive_active_snapshot_async(visual_additive_active),
        .additive_level_snapshot_async(visual_additive_level),
        .spectrum_bins_async(spectrum_magnitudes),
        .spectrum_toggle_async(spectrum_update_toggle),
        .rgb(visualizer_rgb)
    );
    // Physical key state for display, independent of the four audio voices.
    // Note Off clears the key even while CC64 keeps its sound alive.
    reg [127:0] held_notes;
    always @(posedge sys_clk or negedge voice_rst_n) begin
        if (!voice_rst_n)
            held_notes <= 128'd0;
        else if (frame_valid) begin
            if (event_type == 8'h01 && data2[6:0] != 7'd0)
                held_notes[data1[6:0]] <= 1'b1;
            else if (event_type == 8'h02 ||
                    (event_type == 8'h01 && data2[6:0] == 7'd0))
                held_notes[data1[6:0]] <= 1'b0;
            else if (event_type == 8'h03 && data1 == 8'd123)
                held_notes <= 128'd0;
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [127:0] held_notes_video_1;
    (* ASYNC_REG = "TRUE" *) reg [127:0] held_notes_video_2;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            held_notes_video_1 <= 128'd0;
            held_notes_video_2 <= 128'd0;
        end else begin
            held_notes_video_1 <= held_notes;
            held_notes_video_2 <= held_notes_video_1;
        end
    end
    wire [23:0] piano_demo_rgb;
    wire [11:0] demo_scroll_px;
    wire [31:0] demo_current_tick;
    wire preview_cache_loaded;
    wire [15:0] preview_cache_bpm;
    wire [31:0] preview_loop_ticks;
    wire [19:0] preview_valid_mask_sys;
    wire [239:0] preview_start_px_sys,preview_length_px_sys;
    wire [199:0] preview_x_left_sys,preview_x_right_sys;
    wire [39:0] preview_part_sys;
    piano_preview_cache u_piano_preview_cache (
        .clk(sys_clk),.rst_n(core_rst_n),.clear(preview_request),
        .note_valid(preview_note_valid),.note_index(preview_note_index),
        .start_tick(preview_start_tick),
        .duration_tick(preview_duration_tick),
        .pitch(preview_pitch),.part_mask(preview_part_mask),
        .read_done(preview_done),.read_available(preview_available),
        .read_bpm(preview_bpm),.loaded(preview_cache_loaded),
        .bpm(preview_cache_bpm),.loop_ticks(preview_loop_ticks),
        .valid_mask(preview_valid_mask_sys),
        .start_px_bus(preview_start_px_sys),
        .length_px_bus(preview_length_px_sys),
        .x_left_bus(preview_x_left_sys),
        .x_right_bus(preview_x_right_sys),.part_bus(preview_part_sys)
    );
    (* ASYNC_REG = "TRUE" *) reg [1:0] preview_loaded_video_sync;
    reg [15:0] preview_bpm_video_1,preview_bpm_video_2;
    reg [31:0] preview_loop_video_1,preview_loop_video_2;
    reg [19:0] preview_mask_video_1,preview_mask_video_2;
    reg [239:0] preview_start_video_1,preview_start_video_2;
    reg [239:0] preview_length_video_1,preview_length_video_2;
    reg [199:0] preview_xleft_video_1,preview_xleft_video_2;
    reg [199:0] preview_xright_video_1,preview_xright_video_2;
    reg [39:0] preview_part_video_1,preview_part_video_2;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            preview_loaded_video_sync<=0;
            preview_bpm_video_1<=0;preview_bpm_video_2<=0;
            preview_loop_video_1<=0;preview_loop_video_2<=0;
            preview_mask_video_1<=0;preview_mask_video_2<=0;
            preview_start_video_1<=0;preview_start_video_2<=0;
            preview_length_video_1<=0;preview_length_video_2<=0;
            preview_xleft_video_1<=0;preview_xleft_video_2<=0;
            preview_xright_video_1<=0;preview_xright_video_2<=0;
            preview_part_video_1<=0;preview_part_video_2<=0;
        end else begin
            preview_loaded_video_sync<=
                {preview_loaded_video_sync[0],preview_cache_loaded};
            preview_bpm_video_1<=preview_cache_bpm;
            preview_bpm_video_2<=preview_bpm_video_1;
            preview_loop_video_1<=preview_loop_ticks;
            preview_loop_video_2<=preview_loop_video_1;
            preview_mask_video_1<=preview_valid_mask_sys;
            preview_mask_video_2<=preview_mask_video_1;
            preview_start_video_1<=preview_start_px_sys;
            preview_start_video_2<=preview_start_video_1;
            preview_length_video_1<=preview_length_px_sys;
            preview_length_video_2<=preview_length_video_1;
            preview_xleft_video_1<=preview_x_left_sys;
            preview_xleft_video_2<=preview_xleft_video_1;
            preview_xright_video_1<=preview_x_right_sys;
            preview_xright_video_2<=preview_xright_video_1;
            preview_part_video_1<=preview_part_sys;
            preview_part_video_2<=preview_part_video_1;
        end
    end
    score_demo_clock #(.CLOCK_HZ(50000000),.STOP_AT_END(0))
        u_score_demo_clock (
        .pixel_clk(sys_clk), .rst_n(core_rst_n),
        .active(piano_demo_mode && preview_cache_loaded),
        .paused(preview_paused_sys),
        .bpm(preview_cache_bpm),
        .loop_ticks(preview_loop_ticks),
        .current_tick(demo_current_tick),.current_scroll_px(demo_scroll_px)
    );
    // Keep onset scoring aligned with the visible 20-NOTE roll excerpt.
    // 7169 ticks is the first point where the Q16 scroll reaches 360 pixels,
    // taking a block from y=40 to the y=400 key line.
    // Score only real Note On traffic; the KEY2 synthetic test is excluded.
    reg [31:0] demo_tick_previous;
    reg practice_event_pending;
    reg [31:0] practice_event_tick;
    reg [6:0] practice_event_pitch;
    wire practice_event_ready,practice_hit,practice_miss;
    wire [2:0] practice_hit_kind;
    wire [4:0] practice_hit_index,practice_miss_index;
    wire practice_restart=demo_current_tick<demo_tick_previous;
    wire [15:0] practice_effective_bpm=
        (preview_cache_bpm>=16'd20 && preview_cache_bpm<=16'd300) ?
        preview_cache_bpm : 16'd112;
    wire practice_active=piano_demo_mode && preview_cache_loaded &&
        !preview_paused_sys && !spectrum_test_active;
    wire real_note_on=frame_valid && !spectrum_test_active &&
        event_type==8'h01 && data2[6:0]!=0 && data1<8'd128;
    always @(posedge sys_clk or negedge core_rst_n) begin
        if(!core_rst_n) begin
            demo_tick_previous<=0;
            practice_event_pending<=0;
            practice_event_tick<=0;
            practice_event_pitch<=0;
        end else begin
            demo_tick_previous<=demo_current_tick;
            if(preview_request || !practice_active || practice_restart)
                practice_event_pending<=0;
            else if(real_note_on && demo_current_tick>=32'd6929) begin
                practice_event_pending<=1;
                practice_event_tick<=demo_current_tick;
                practice_event_pitch<=data1[6:0];
            end else if(practice_event_pending && practice_event_ready)
                practice_event_pending<=0;
        end
    end
    practice_onset_match #(.TARGETS(20),.INDEX_BITS(5))
        u_practice_onset_match (
        .clk(sys_clk),.rst_n(core_rst_n),
        .clear(preview_request),.restart(practice_restart),
        .target_valid(preview_note_valid && preview_note_index<20),
        .target_index(preview_note_index[4:0]),
        .target_tick(preview_start_tick+32'd7169),
        .target_pitch(preview_pitch),.target_part(preview_part_mask),
        .target_score_onset(preview_score_onset),
        .selected_parts(2'b11),.bpm(practice_effective_bpm),
        .event_valid(practice_event_pending && practice_active &&
                     demo_current_tick>=32'd6929),
        .event_tick(practice_event_tick),
        .event_pitch(practice_event_pitch),
        .event_ready(practice_event_ready),
        .hit_valid(practice_hit),.hit_kind(practice_hit_kind),
        .hit_index(practice_hit_index),
        .sweep_valid(practice_active &&
                     demo_current_tick!=demo_tick_previous &&
                     demo_current_tick>=32'd6929),
        .sweep_tick(demo_current_tick),
        .miss_valid(practice_miss),.miss_index(practice_miss_index)
    );
    wire [6:0] practice_combo,practice_max_combo;
    wire [6:0] practice_perfect_count,practice_good_count;
    wire [6:0] practice_miss_count,practice_wrong_count;
    practice_onset_stats u_practice_onset_stats (
        .clk(sys_clk),.rst_n(core_rst_n),
        .clear(preview_request),.restart(practice_restart),
        .hit_valid(practice_hit),.hit_kind(practice_hit_kind),
        .miss_valid(practice_miss),
        .combo(practice_combo),.max_combo(practice_max_combo),
        .perfect_count(practice_perfect_count),
        .good_count(practice_good_count),
        .miss_count(practice_miss_count),
        .wrong_count(practice_wrong_count)
    );
    reg [2:0] practice_status_sys;
    always @(posedge sys_clk or negedge core_rst_n) begin
        if(!core_rst_n) practice_status_sys<=0;
        else if(preview_request || practice_restart || !piano_demo_mode)
            practice_status_sys<=0;
        else if(practice_miss) practice_status_sys<=3'd6;
        else if(practice_hit) practice_status_sys<=practice_hit_kind+3'd1;
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] practice_status_meta;
    (* ASYNC_REG = "TRUE" *) reg [2:0] practice_status_video;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            practice_status_meta<=0;practice_status_video<=0;
        end else begin
            practice_status_meta<=practice_status_sys;
            practice_status_video<=practice_status_meta;
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [6:0] practice_combo_video_meta;
    (* ASYNC_REG = "TRUE" *) reg [6:0] practice_combo_video_sync;
    reg [6:0] practice_combo_frame;
    wire [27:0] practice_counts_sys={practice_perfect_count,
        practice_good_count,practice_miss_count,practice_wrong_count};
    (* ASYNC_REG = "TRUE" *) reg [27:0] practice_counts_video_meta;
    (* ASYNC_REG = "TRUE" *) reg [27:0] practice_counts_video_sync;
    reg [27:0] practice_counts_frame;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            practice_combo_video_meta<=0;
            practice_combo_video_sync<=0;
            practice_combo_frame<=0;
            practice_counts_video_meta<=0;
            practice_counts_video_sync<=0;
            practice_counts_frame<=0;
        end else begin
            practice_combo_video_meta<=practice_combo;
            practice_combo_video_sync<=practice_combo_video_meta;
            practice_counts_video_meta<=practice_counts_sys;
            practice_counts_video_sync<=practice_counts_video_meta;
            if(video_de && video_x==10'd0 && video_y==10'd0) begin
                practice_combo_frame<=practice_combo_video_sync;
                practice_counts_frame<=practice_counts_video_sync;
            end
        end
    end
    // Gray-code the slowly advancing scroll before crossing to pixel_clk;
    // a binary carry would otherwise allow a one-frame coordinate tear.
    wire [11:0] demo_scroll_gray=demo_scroll_px^(demo_scroll_px>>1);
    (* ASYNC_REG = "TRUE" *) reg [11:0] demo_scroll_meta;
    (* ASYNC_REG = "TRUE" *) reg [11:0] demo_scroll_gray_video;
    reg [11:0] demo_scroll_video;
    integer scroll_bit;
    always @* begin
        demo_scroll_video[11]=demo_scroll_gray_video[11];
        for(scroll_bit=10;scroll_bit>=0;scroll_bit=scroll_bit-1)
            demo_scroll_video[scroll_bit]=demo_scroll_video[scroll_bit+1]^
                                          demo_scroll_gray_video[scroll_bit];
    end
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            demo_scroll_meta<=0;demo_scroll_gray_video<=0;
        end else begin
            demo_scroll_meta<=demo_scroll_gray;
            demo_scroll_gray_video<=demo_scroll_meta;
        end
    end
    // Snapshot the independent music clock once per video frame. Rendering
    // stays stable across a frame; the clock itself never waits for HDMI.
    reg [11:0] demo_display_scroll_px;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if (!video_rst_n)
            demo_display_scroll_px <= 12'd0;
        else if (!demo_mode_video_sync[1])
            demo_display_scroll_px <= 12'd0;
        else if (video_de && video_x == 10'd0 && video_y == 10'd0)
            demo_display_scroll_px <= demo_scroll_video;
    end
    piano_blocks_demo u_piano_blocks_demo (
        .de(video_de),
        .pix_x(video_x), .pix_y(video_y),
        .scroll_px_in(demo_display_scroll_px),
        .note_on_mask(held_notes_video_2),
        .preview_loaded(preview_loaded_video_sync[1]),
        .preview_paused(paused_video_sync[1]),
        .preview_valid_mask(preview_mask_video_2),
        .preview_start_px(preview_start_video_2),
        .preview_length_px(preview_length_video_2),
        .preview_x_left(preview_xleft_video_2),
        .preview_x_right(preview_xright_video_2),
        .preview_part(preview_part_video_2),
        .rgb(piano_demo_rgb)
    );
    (* ASYNC_REG = "TRUE" *) reg [1:0] spectrum_mode_video_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] echo_mode_video_sync;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            spectrum_mode_video_sync <= 2'b00;
            echo_mode_video_sync <= 2'b00;
        end else begin
            spectrum_mode_video_sync <= {spectrum_mode_video_sync[0],
                                         spectrum_test_active};
            echo_mode_video_sync <= {echo_mode_video_sync[0],echo_enabled};
        end
    end
    wire practice_badge=video_de && video_y>=10'd9 &&
        video_y<10'd27 && video_x>=10'd10 && video_x<10'd34 &&
        practice_status_video!=0;
    wire practice_combo_pixel;
    practice_combo_video u_practice_combo_video (
        .de(video_de),.x(video_x),.y(video_y),
        .combo(practice_combo_frame),.pixel_on(practice_combo_pixel)
    );
    wire practice_stats_pixel;
    wire [23:0] practice_stats_rgb;
    practice_stats_video u_practice_stats_video (
        .de(video_de),.x(video_x),.y(video_y),
        .perfect_count(practice_counts_frame[27:21]),
        .good_count(practice_counts_frame[20:14]),
        .miss_count(practice_counts_frame[13:7]),
        .wrong_count(practice_counts_frame[6:0]),
        .pixel_on(practice_stats_pixel),.pixel_rgb(practice_stats_rgb)
    );
    reg [23:0] practice_badge_rgb;
    always @* begin
        case(practice_status_video)
            3'd1:practice_badge_rgb=24'hF04444; // extra wrong note
            3'd2:practice_badge_rgb=24'h58BBD8; // unscored reference
            3'd3:practice_badge_rgb=24'hFACC15; // Good
            3'd4:practice_badge_rgb=24'h24D883; // Perfect
            3'd5:practice_badge_rgb=24'h7496C9; // unselected part
            3'd6:practice_badge_rgb=24'hD85A30; // missed target
            default:practice_badge_rgb=24'h102A50;
        endcase
    end
    wire [23:0] video_rgb_base = (demo_mode_video_sync[1] &&
                                  !spectrum_mode_video_sync[1]) ?
                                   (practice_combo_pixel ? 24'hF8FAFC :
                                    practice_stats_pixel ? practice_stats_rgb :
                                    practice_badge ? practice_badge_rgb :
                                    piano_demo_rgb) : visualizer_rgb;
    // Tiny header glyph: T means internal four-tone test; E means echo on.
    wire mode_icon_area = video_de && video_y >= 10'd8 &&
                          video_y <= 10'd24 && video_x >= 10'd50 &&
                          video_x <= 10'd64;
    wire test_icon = mode_icon_area && spectrum_mode_video_sync[1] &&
                     ((video_y <= 10'd10) ||
                      (video_x >= 10'd56 && video_x <= 10'd58));
    wire echo_icon = mode_icon_area && !spectrum_mode_video_sync[1] &&
                     echo_mode_video_sync[1] &&
                     ((video_x <= 10'd52) || (video_y <= 10'd10) ||
                      (video_y >= 10'd15 && video_y <= 10'd17) ||
                      (video_y >= 10'd22));
    reg [23:0] video_rgb_base_q;
    reg test_icon_q,echo_icon_q,sheet_mode_q,page_status_bar_q;
    reg page_code_area_q,page_code_bit_q,diag_grid_area_q,diag_grid_bit_q;
    reg [23:0] page_status_rgb_q;
    reg video_de_pre,video_hsync_pre,video_vsync_pre;
    // Only persistent read failures need an on-screen diagnostic. Request,
    // loading and ready stages must not flash the old debug color bar while
    // entering a score page or switching between notation types.
    wire sheet_page_error = (page_stage_video_sync>=4'd3 &&
                             page_stage_video_sync<=4'd6) ||
                            (page_stage_video_sync>=4'd8 &&
                             page_stage_video_sync<=4'd12);
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            video_rgb_base_q<=0;
            test_icon_q<=0;echo_icon_q<=0;sheet_mode_q<=0;
            page_status_bar_q<=0;page_status_rgb_q<=0;
            page_code_area_q<=0;page_code_bit_q<=0;
            diag_grid_area_q<=0;diag_grid_bit_q<=0;
            video_de_pre<=0;video_hsync_pre<=1;video_vsync_pre<=1;
        end else begin
            video_rgb_base_q<=video_rgb_base;
            test_icon_q<=test_icon;
            echo_icon_q<=echo_icon;
            sheet_mode_q<=sheet_mode_video_sync[1] &&
                          !spectrum_mode_video_sync[1];
            page_status_bar_q<=video_de && video_y<10'd16 &&
                               sheet_page_error;
            // First 256 pixels of the status bar encode the exact four-bit
            // result: four 64-pixel blocks, MSB first; white=1, black=0.
            // This remains readable in photos even when color balance shifts.
            page_code_area_q<=video_x<10'd256;
            // The diagnostic grid is reserved for actual read errors.
            diag_grid_area_q<=video_de && video_x<10'd512 &&
                video_y>=10'd32 && video_y<10'd288 &&
                sheet_page_error &&
                (video_y<10'd64 || page_stage_video_sync==4'd10);
            diag_grid_bit_q<=page_diag_word[5'd31-video_x[8:4]];
            case(video_x[7:6])
                2'd0:page_code_bit_q<=page_stage_video_sync[3];
                2'd1:page_code_bit_q<=page_stage_video_sync[2];
                2'd2:page_code_bit_q<=page_stage_video_sync[1];
                default:page_code_bit_q<=page_stage_video_sync[0];
            endcase
            case(page_stage_video_sync)
                4'd3:page_status_rgb_q<=24'hFF2020; // no saved song: red
                4'd4:page_status_rgb_q<=24'hFF8000; // SD I/O: orange
                4'd5:page_status_rgb_q<=24'hFF00FF; // file < 57600: magenta
                4'd6:page_status_rgb_q<=24'h0080FF; // page absent: blue
                4'd8:page_status_rgb_q<=24'hFFB000; // reader input: amber
                4'd9:page_status_rgb_q<=24'hA000FF; // offset >= file: violet
                4'd10:page_status_rgb_q<=24'hFF4080; // length: pink
                4'd11:page_status_rgb_q<=24'h00FF80; // crosses EOF: mint
                4'd12:page_status_rgb_q<=video_x[5] ?
                    24'hFFFF00 : 24'h0000FF; // short catalog: blue/yellow stripes
                default:page_status_rgb_q<=24'h000000; // no error overlay
            endcase
            video_de_pre<=video_de;
            video_hsync_pre<=video_hsync;
            video_vsync_pre<=video_vsync;
        end
    end
    wire [23:0] video_rgb_raw = sheet_mode_q ?
        (page_status_bar_q ?
            (page_code_area_q ?
                (page_code_bit_q ? 24'hFFFFFF : 24'h000000) :
                page_status_rgb_q) :
            (diag_grid_area_q ?
                (diag_grid_bit_q ? 24'hFFFFFF : 24'h000000) :
                sheet_rgb)) :
        test_icon_q ? 24'hFACC15 :
        echo_icon_q ? 24'h34D399 : video_rgb_base_q;

    // One pixel of pipeline latency isolates the relatively rich dashboard
    // drawing logic from the TMDS encoder. Delay control signals by the same
    // amount so active-video and sync alignment is preserved.
    reg [23:0] video_rgb;
    reg video_de_pipe, video_hsync_pipe, video_vsync_pipe;
    always @(posedge pixel_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            video_rgb <= 24'd0;
            video_de_pipe <= 1'b0;
            video_hsync_pipe <= 1'b0;
            video_vsync_pipe <= 1'b0;
        end else begin
            video_rgb <= video_rgb_raw;
            video_de_pipe <= video_de_pre;
            video_hsync_pipe <= video_hsync_pre;
            video_vsync_pipe <= video_vsync_pre;
        end
    end

    wire [9:0] tmds_b, tmds_g, tmds_r;
    dvi_tmds_encoder u_tmds_b (
        .pixel_clk(pixel_clk), .rst_n(video_rst_n), .de(video_de_pipe),
        .data(video_rgb[7:0]), .c0(video_hsync_pipe), .c1(video_vsync_pipe), .tmds(tmds_b)
    );
    dvi_tmds_encoder u_tmds_g (
        .pixel_clk(pixel_clk), .rst_n(video_rst_n), .de(video_de_pipe),
        .data(video_rgb[15:8]), .c0(1'b0), .c1(1'b0), .tmds(tmds_g)
    );
    dvi_tmds_encoder u_tmds_r (
        .pixel_clk(pixel_clk), .rst_n(video_rst_n), .de(video_de_pipe),
        .data(video_rgb[23:16]), .c0(1'b0), .c1(1'b0), .tmds(tmds_r)
    );

    dvi_tmds_lane u_lane_b (.pixel_clk(pixel_clk), .serial_clk(serial_clk), .rst_n(video_rst_n), .symbol(tmds_b), .out_p(tmds_d_p_0[0]), .out_n(tmds_d_n_0[0]));
    dvi_tmds_lane u_lane_g (.pixel_clk(pixel_clk), .serial_clk(serial_clk), .rst_n(video_rst_n), .symbol(tmds_g), .out_p(tmds_d_p_0[1]), .out_n(tmds_d_n_0[1]));
    dvi_tmds_lane u_lane_r (.pixel_clk(pixel_clk), .serial_clk(serial_clk), .rst_n(video_rst_n), .symbol(tmds_r), .out_p(tmds_d_p_0[2]), .out_n(tmds_d_n_0[2]));
    dvi_clock_lane u_lane_clk (.pixel_clk(pixel_clk), .out_p(tmds_clk_p_0), .out_n(tmds_clk_n_0));
endmodule
