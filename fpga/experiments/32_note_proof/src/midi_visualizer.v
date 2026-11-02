module midi_visualizer (
    input  wire               pixel_clk,
    input  wire               rst_n,
    input  wire               de,
    input  wire [9:0]         pix_x,
    input  wire [9:0]         pix_y,
    input  wire signed [15:0] audio_snapshot_async,
    input  wire               snapshot_toggle_async,
    input  wire               timbre_snapshot_async,
    input  wire [1:0]         program_snapshot_async,
    input  wire               additive_active_snapshot_async,
    input  wire [7:0]         additive_level_snapshot_async,
    input  wire [255:0]       spectrum_bins_async,
    input  wire               spectrum_toggle_async,
    output reg  [23:0]        rgb
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sample_toggle_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] spectrum_toggle_sync;
    reg sample_toggle_seen, spectrum_toggle_seen;
    reg timbre_select;
    reg [1:0] program_select;
    reg additive_active;
    reg [7:0] additive_level;
    reg [1:0] waveform_decimator;
    reg [255:0] spectrum_bins;

    // Separate acquisition and display memories are essential. The old
    // continuously shifted array changed while the raster scanned a frame,
    // so the left and right sides represented different instants (tearing).
    reg signed [7:0] capture_buffer [0:127];
    reg signed [7:0] display_buffer [0:127];
    reg signed [7:0] previous_sample;
    reg trigger_armed;
    reg capture_active;
    reg capture_ready;
    reg [6:0] capture_index;
    integer capture_i;
    integer spectrum_i;

    wire frame_start = (pix_x == 10'd0) && (pix_y == 10'd0);

    function signed [7:0] display_wave_sample;
        input signed [15:0] sample_value;
        begin
            if (sample_value > 16'sd8191)
                display_wave_sample = 8'sd127;
            else if (sample_value < -16'sd8192)
                display_wave_sample = -8'sd128;
            else
                display_wave_sample = sample_value[13:6];
        end
    endfunction

    // Display-only, logarithmically compressed heights for the 1/n gain
    // table in additive32_synth. These are synthesis coefficients, NOT
    // measured FFT magnitudes. Index 0 is the fundamental, index 31 is H32.
    function [7:0] harmonic_height_base;
        input [4:0] index;
        begin
            case (index)
                5'd0: harmonic_height_base=8'd202;
                5'd1: harmonic_height_base=8'd178;
                5'd2: harmonic_height_base=8'd164;
                5'd3: harmonic_height_base=8'd152;
                5'd4: harmonic_height_base=8'd143;
                5'd5: harmonic_height_base=8'd136;
                5'd6: harmonic_height_base=8'd130;
                5'd7: harmonic_height_base=8'd124;
                5'd8: harmonic_height_base=8'd119;
                5'd9: harmonic_height_base=8'd115;
                5'd10: harmonic_height_base=8'd111;
                5'd11: harmonic_height_base=8'd108;
                5'd12: harmonic_height_base=8'd105;
                5'd13: harmonic_height_base=8'd102;
                5'd14: harmonic_height_base=8'd99;
                5'd15: harmonic_height_base=8'd96;
                5'd16: harmonic_height_base=8'd94;
                5'd17: harmonic_height_base=8'd91;
                5'd18: harmonic_height_base=8'd89;
                5'd19: harmonic_height_base=8'd87;
                5'd20: harmonic_height_base=8'd85;
                5'd21: harmonic_height_base=8'd83;
                5'd22: harmonic_height_base=8'd82;
                5'd23: harmonic_height_base=8'd80;
                5'd24: harmonic_height_base=8'd78;
                5'd25: harmonic_height_base=8'd77;
                5'd26: harmonic_height_base=8'd75;
                5'd27: harmonic_height_base=8'd74;
                5'd28: harmonic_height_base=8'd73;
                5'd29: harmonic_height_base=8'd71;
                5'd30: harmonic_height_base=8'd70;
                default: harmonic_height_base=8'd68;
            endcase
        end
    endfunction

    wire signed [7:0] incoming_display_sample =
        display_wave_sample(audio_snapshot_async);

    // Log-like height mapping exposes quiet harmonics without allowing one
    // strong fundamental to pin all useful bars at full height.
    function [7:0] spectrum_height_log;
        input [7:0] value;
        begin
            if (value == 0)       spectrum_height_log = 8'd0;
            else if (value < 2)   spectrum_height_log = 8'd14;
            else if (value < 4)   spectrum_height_log = 8'd32;
            else if (value < 8)   spectrum_height_log = 8'd52;
            else if (value < 16)  spectrum_height_log = 8'd78;
            else if (value < 32)  spectrum_height_log = 8'd110;
            else if (value < 64)  spectrum_height_log = 8'd140;
            else if (value < 128) spectrum_height_log = 8'd174;
            else                  spectrum_height_log = 8'd202;
        end
    endfunction

    // Triggered acquisition at 12.2 ksample/s. The completed trace is copied
    // to the visible buffer only at a video-frame boundary.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_toggle_sync <= 2'b00;
            spectrum_toggle_sync <= 2'b00;
            sample_toggle_seen <= 1'b0;
            spectrum_toggle_seen <= 1'b0;
            timbre_select <= 1'b0;
            program_select <= 2'd0;
            additive_active <= 1'b0;
            additive_level <= 8'd0;
            waveform_decimator <= 2'd0;
            spectrum_bins <= 256'd0;
            previous_sample <= 8'sd0;
            trigger_armed <= 1'b0;
            capture_active <= 1'b0;
            capture_ready <= 1'b0;
            capture_index <= 7'd0;
            for (capture_i = 0; capture_i < 128; capture_i = capture_i + 1) begin
                capture_buffer[capture_i] <= 8'sd0;
                display_buffer[capture_i] <= 8'sd0;
            end
        end else begin
            sample_toggle_sync <= {sample_toggle_sync[0], snapshot_toggle_async};
            spectrum_toggle_sync <= {spectrum_toggle_sync[0], spectrum_toggle_async};

            if (frame_start && capture_ready) begin
                for (capture_i = 0; capture_i < 128; capture_i = capture_i + 1)
                    display_buffer[capture_i] <= capture_buffer[capture_i];
                capture_ready <= 1'b0;
            end

            if (sample_toggle_sync[1] != sample_toggle_seen) begin
                sample_toggle_seen <= sample_toggle_sync[1];
                timbre_select <= timbre_snapshot_async;
                program_select <= program_snapshot_async;
                additive_active <= additive_active_snapshot_async;
                additive_level <= additive_level_snapshot_async;
                if (waveform_decimator == 2'd3) begin
                    waveform_decimator <= 2'd0;
                    previous_sample <= incoming_display_sample;
                    if (capture_active) begin
                        capture_buffer[capture_index] <= incoming_display_sample;
                        if (capture_index == 7'd127) begin
                            capture_active <= 1'b0;
                            capture_ready <= 1'b1;
                            capture_index <= 7'd0;
                        end else begin
                            capture_index <= capture_index + 1'b1;
                        end
                    end else if (!capture_ready) begin
                        // Hysteresis rejects tiny idle noise near zero.
                        if (incoming_display_sample <= -8'sd6)
                            trigger_armed <= 1'b1;
                        if (trigger_armed && incoming_display_sample >= 8'sd0) begin
                            capture_buffer[0] <= incoming_display_sample;
                            capture_index <= 7'd1;
                            capture_active <= 1'b1;
                            trigger_armed <= 1'b0;
                        end
                    end
                end else begin
                    waveform_decimator <= waveform_decimator + 1'b1;
                end
            end

            if (spectrum_toggle_sync[1] != spectrum_toggle_seen) begin
                spectrum_toggle_seen <= spectrum_toggle_sync[1];
                // Peak hold with slow decay belongs in this relaxed 25 MHz
                // display domain, not in the FFT's 50 MHz critical path.
                for (spectrum_i = 0; spectrum_i < 32; spectrum_i = spectrum_i + 1) begin
                    if (spectrum_bins_async[(spectrum_i * 8) +: 8] >=
                        spectrum_bins[(spectrum_i * 8) +: 8])
                        spectrum_bins[(spectrum_i * 8) +: 8] <=
                            spectrum_bins_async[(spectrum_i * 8) +: 8];
                    else if (spectrum_bins[(spectrum_i * 8) +: 8] > 8'd2)
                        spectrum_bins[(spectrum_i * 8) +: 8] <=
                            spectrum_bins[(spectrum_i * 8) +: 8] - 8'd2;
                    else
                        spectrum_bins[(spectrum_i * 8) +: 8] <= 8'd0;
                end
            end
        end
    end

    integer wave_index, wave_y, wave_next_y, wave_y_min, wave_y_max;
    integer spectrum_bin, spectrum_x0, spectrum_height, spectrum_top;
    reg [7:0] spectrum_value;
    reg [15:0] harmonic_scaled;

    always @* begin
        rgb = 24'h050A14;
        wave_index = 0;
        wave_y = 134;
        wave_next_y = 134;
        wave_y_min = 134;
        wave_y_max = 134;
        spectrum_bin = 0;
        spectrum_x0 = 64;
        spectrum_value = 0;
        spectrum_height = 0;
        spectrum_top = 450;
        harmonic_scaled = 16'd0;

        if (!de) begin
            rgb = 24'h000000;
        end else begin
            // Minimal header. P = piano, O = organ, A = 32-partial additive,
            // X = experimental 32-note lightweight polyphony.
            if (pix_y < 32) rgb = 24'h0B1730;
            if (pix_y >= 8 && pix_y <= 24 && pix_x >= 18 && pix_x <= 34) begin
                if (program_select == 2'd3) begin
                    if (((pix_x - 18) >= (pix_y - 8) &&
                         (pix_x - 18) <= (pix_y - 8) + 1) ||
                        ((pix_x - 18) + (pix_y - 8) >= 15 &&
                         (pix_x - 18) + (pix_y - 8) <= 17))
                        rgb = 24'h34D399;
                end else if (program_select == 2'd2) begin
                    if ((pix_y <= 10) || (pix_y >= 15 && pix_y <= 17) ||
                        (pix_x <= 20) || (pix_x >= 32)) begin
                        if (!(pix_y >= 18 && pix_x >= 22 && pix_x <= 30))
                            rgb = 24'hA78BFA;
                    end else if (pix_y >= 18 && (pix_x <= 20 || pix_x >= 32))
                        rgb = 24'hA78BFA;
                end else if (!timbre_select) begin
                    if ((pix_x <= 20) || (pix_y <= 10) ||
                        (pix_y >= 15 && pix_y <= 17) ||
                        (pix_x >= 31 && pix_y <= 17)) rgb = 24'h60A5FA;
                end else begin
                    if ((pix_x <= 20) || (pix_x >= 32) ||
                        (pix_y <= 10) || (pix_y >= 22)) rgb = 24'hF59E0B;
                end
            end
            if (pix_y >= 14 && pix_y <= 18 && pix_x >= 430 && pix_x <= 590)
                rgb = timbre_select ? 24'hF59E0B : 24'h38BDF8;

            // Upper panel: triggered waveform of the loudest active voice.
            if (pix_x >= 48 && pix_x <= 591 && pix_y >= 42 && pix_y <= 226) begin
                if ((pix_x == 48) || (pix_x == 591) ||
                    (pix_y == 42) || (pix_y == 226))
                    rgb = 24'h31527A;
                else if ((pix_y == 88) || (pix_y == 134) || (pix_y == 180) ||
                         (((pix_x - 48) & 10'h07F) == 0))
                    rgb = 24'h14243A;
                if (pix_x >= 64 && pix_x < 572) begin
                    wave_index = (pix_x - 64) >> 2;
                    wave_y = 134 - ($signed(display_buffer[wave_index]) >>> 1);
                    wave_next_y = 134 - ($signed(display_buffer[wave_index + 1]) >>> 1);
                    wave_y_min = (wave_y < wave_next_y) ? wave_y : wave_next_y;
                    wave_y_max = (wave_y > wave_next_y) ? wave_y : wave_next_y;
                    if (pix_y >= wave_y_min - 1 && pix_y <= wave_y_max + 1)
                        rgb = timbre_select ? 24'hFCD34D : 24'h67E8F9;
                end
            end

            // P/O: peak-held FFT of the mix. A: the 32 synthesis-coefficient
            // contributions of the active voice (not 32 measured FFT peaks).
            if (pix_x >= 48 && pix_x <= 591 && pix_y >= 248 && pix_y <= 466) begin
                if ((pix_x == 48) || (pix_x == 591) ||
                    (pix_y == 248) || (pix_y == 466))
                    rgb = 24'h31527A;
                else if ((pix_y == 300) || (pix_y == 352) ||
                         (pix_y == 404) || (pix_y == 450))
                    rgb = 24'h14243A;
                // The H glyph identifies the harmonic-coefficient view.
                if (program_select == 2'd2 && additive_active &&
                    pix_y >= 258 && pix_y <= 270 &&
                    ((pix_x >= 53 && pix_x <= 54) ||
                     (pix_x >= 60 && pix_x <= 61) ||
                     (pix_y >= 263 && pix_y <= 265 &&
                      pix_x >= 53 && pix_x <= 61)))
                    rgb = 24'hA78BFA;
                if (pix_x >= 64 && pix_x < 576) begin
                    spectrum_bin = (pix_x - 64) >> 4;
                    spectrum_x0 = 64 + (spectrum_bin << 4);
                    if (program_select == 2'd2 && additive_active) begin
                        harmonic_scaled = harmonic_height_base(spectrum_bin[4:0]) *
                                          additive_level;
                        spectrum_height = harmonic_scaled >> 8;
                    end else begin
                        spectrum_value = spectrum_bins[(spectrum_bin * 8) +: 8];
                        spectrum_height = spectrum_height_log(spectrum_value);
                    end
                    spectrum_top = 450 - spectrum_height;
                    if (pix_x >= spectrum_x0 + 2 && pix_x <= spectrum_x0 + 13 &&
                        spectrum_height != 0 && pix_y >= spectrum_top &&
                        pix_y <= 450) begin
                        if (program_select == 2'd2 && additive_active)
                            rgb = 24'hA78BFA;
                        else if (pix_y < 310) rgb = 24'hFB7185;
                        else if (pix_y < 380) rgb = 24'hFBBF24;
                        else rgb = 24'h22D3EE;
                    end
                end
            end
        end
    end
endmodule
