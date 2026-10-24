module basic_dds_synth (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire [6:0]         note,
    input  wire [6:0]         velocity,
    input  wire               gate,
    input  wire               retrigger,
    input  wire               timbre_select,
    input  wire [15:0]        bend_factor_q14,
    output reg signed [15:0]  audio_sample,
    output reg  [7:0]         envelope_level,
    output reg                voice_finished,
    output wire [31:0]       phase_out,
    output wire [31:0]       phase_step_out
);
    localparam [2:0] ENV_IDLE    = 3'd0;
    localparam [2:0] ENV_ATTACK  = 3'd1;
    localparam [2:0] ENV_DECAY   = 3'd2;
    localparam [2:0] ENV_ORGAN_HOLD = 3'd3;
    localparam [2:0] ENV_RELEASE = 3'd4;
    localparam [2:0] ENV_ORGAN_FADE = 3'd5;
    reg [31:0] phase;
    assign phase_out = phase;
    reg [7:0] strike_level;
    reg [2:0] strike_divider;
    reg [7:0] piano_tone_level;
    reg [7:0] piano_tone_divider;
    reg [2:0] envelope_state;
    reg [10:0] decay_divider;
    reg [4:0] release_divider;
    reg [14:0] organ_hold_count;
    reg voice_timbre;
    reg [31:0] phase_step_base_q;
    reg [47:0] phase_step_product_q;
    wire [31:0] phase_step_bent = phase_step_product_q[45:14];
    assign phase_step_out = phase_step_bent;

    // The note lookup and bend multiplication are pipelined at 50 MHz.
    // An event settles long before the next 48.828 kHz sample tick.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_step_base_q <= 32'd0;
            phase_step_product_q <= 48'd0;
        end else begin
            phase_step_base_q <= note_phase_inc(note);
            phase_step_product_q <= phase_step_base_q * bend_factor_q14;
        end
    end

    // Two distinct, fully generated presets. Piano uses a soft harmonic
    // stack with a brighter hammer transient.  The second preset is an
    // additive drawbar-organ voice: integer sine harmonics plus a sustained
    // envelope. No recorded PCM is stored in the FPGA.
    function signed [16:0] triangle_from_phase;
        input [31:0] phase_value;
        reg [15:0] triangle_unsigned;
        begin
            triangle_unsigned = phase_value[31] ?
                                ~phase_value[30:15] : phase_value[30:15];
            triangle_from_phase = $signed({1'b0, triangle_unsigned}) - 17'sd32768;
        end
    endfunction

    // 64-step sine oscillator used by the additive organ.  This is a tiny
    // mathematical wavetable for one generated period, not a recorded sound.
    function signed [16:0] sine_from_phase;
        input [31:0] phase_value;
        begin
            case (phase_value[31:26])
                6'd0: sine_from_phase=17'sd0; 6'd1: sine_from_phase=17'sd3212;
                6'd2: sine_from_phase=17'sd6393; 6'd3: sine_from_phase=17'sd9512;
                6'd4: sine_from_phase=17'sd12539; 6'd5: sine_from_phase=17'sd15446;
                6'd6: sine_from_phase=17'sd18204; 6'd7: sine_from_phase=17'sd20787;
                6'd8: sine_from_phase=17'sd23170; 6'd9: sine_from_phase=17'sd25329;
                6'd10: sine_from_phase=17'sd27245; 6'd11: sine_from_phase=17'sd28898;
                6'd12: sine_from_phase=17'sd30273; 6'd13: sine_from_phase=17'sd31356;
                6'd14: sine_from_phase=17'sd32137; 6'd15: sine_from_phase=17'sd32609;
                6'd16: sine_from_phase=17'sd32767; 6'd17: sine_from_phase=17'sd32609;
                6'd18: sine_from_phase=17'sd32137; 6'd19: sine_from_phase=17'sd31356;
                6'd20: sine_from_phase=17'sd30273; 6'd21: sine_from_phase=17'sd28898;
                6'd22: sine_from_phase=17'sd27245; 6'd23: sine_from_phase=17'sd25329;
                6'd24: sine_from_phase=17'sd23170; 6'd25: sine_from_phase=17'sd20787;
                6'd26: sine_from_phase=17'sd18204; 6'd27: sine_from_phase=17'sd15446;
                6'd28: sine_from_phase=17'sd12539; 6'd29: sine_from_phase=17'sd9512;
                6'd30: sine_from_phase=17'sd6393; 6'd31: sine_from_phase=17'sd3212;
                6'd32: sine_from_phase=17'sd0; 6'd33: sine_from_phase=-17'sd3212;
                6'd34: sine_from_phase=-17'sd6393; 6'd35: sine_from_phase=-17'sd9512;
                6'd36: sine_from_phase=-17'sd12539; 6'd37: sine_from_phase=-17'sd15446;
                6'd38: sine_from_phase=-17'sd18204; 6'd39: sine_from_phase=-17'sd20787;
                6'd40: sine_from_phase=-17'sd23170; 6'd41: sine_from_phase=-17'sd25329;
                6'd42: sine_from_phase=-17'sd27245; 6'd43: sine_from_phase=-17'sd28898;
                6'd44: sine_from_phase=-17'sd30273; 6'd45: sine_from_phase=-17'sd31356;
                6'd46: sine_from_phase=-17'sd32137; 6'd47: sine_from_phase=-17'sd32609;
                6'd48: sine_from_phase=-17'sd32767; 6'd49: sine_from_phase=-17'sd32609;
                6'd50: sine_from_phase=-17'sd32137; 6'd51: sine_from_phase=-17'sd31356;
                6'd52: sine_from_phase=-17'sd30273; 6'd53: sine_from_phase=-17'sd28898;
                6'd54: sine_from_phase=-17'sd27245; 6'd55: sine_from_phase=-17'sd25329;
                6'd56: sine_from_phase=-17'sd23170; 6'd57: sine_from_phase=-17'sd20787;
                6'd58: sine_from_phase=-17'sd18204; 6'd59: sine_from_phase=-17'sd15446;
                6'd60: sine_from_phase=-17'sd12539; 6'd61: sine_from_phase=-17'sd9512;
                6'd62: sine_from_phase=-17'sd6393; default: sine_from_phase=-17'sd3212;
            endcase
        end
    endfunction

    // Linear interpolation between adjacent 64-step sine entries removes
    // audible low-note staircase images while keeping the same table and
    // harmonic registration. Ten fractional phase bits are sufficient.
    function signed [16:0] sine_interpolated;
        input [31:0] phase_value;
        reg signed [16:0] sample_a;
        reg signed [16:0] sample_b;
        reg signed [17:0] delta;
        reg signed [28:0] weighted_delta;
        reg signed [17:0] result;
        reg [5:0] next_index;
        begin
            sample_a = sine_from_phase(phase_value);
            next_index = phase_value[31:26] + 6'd1;
            sample_b = sine_from_phase({next_index,26'd0});
            delta = $signed({sample_b[16], sample_b}) -
                    $signed({sample_a[16], sample_a});
            weighted_delta = delta * $signed({1'b0, phase_value[25:16]});
            result = $signed({sample_a[16], sample_a}) +
                     (weighted_delta >>> 10);
            sine_interpolated = result[16:0];
        end
    endfunction

    wire signed [16:0] organ_sine_1 = sine_interpolated(phase);
    wire signed [16:0] organ_sine_2 = sine_interpolated(phase << 1);
    // The third-rank phase adder and interpolation were the 19:01 build's
    // 0.021 ns-slack path. Like ranks 5/6, precompute the phase between
    // audio ticks so the interpolator has a full system-clock cycle.
    reg [31:0] piano_phase_3_q;
    wire signed [16:0] organ_sine_3 = sine_interpolated(piano_phase_3_q);
    wire signed [16:0] organ_sine_4 = sine_interpolated(phase << 2);
    wire signed [16:0] piano_sine_1 = organ_sine_1;
    wire signed [16:0] piano_sine_2 = organ_sine_2;
    wire signed [16:0] piano_sine_3 = organ_sine_3;
    wire signed [16:0] piano_sine_4 = organ_sine_4;
    // Keep the x5 phase adder out of the interpolation path. The phase is
    // updated at the audio-sample boundary, leaving ample clocks for this
    // register to settle before the next sample is consumed.
    reg [31:0] piano_phase_5_q;
    wire signed [16:0] piano_sine_5 =
        sine_interpolated(piano_phase_5_q);
    // The sixth harmonic was the only failing 50 MHz setup path in the
    // 15:49 report: phase -> x6 adder -> sine interpolation. Phase changes
    // only once per 1024 clocks, so this registered product settles long
    // before the next audio sample without changing sample values.
    reg [31:0] piano_phase_6_q;
    wire signed [16:0] piano_sine_6 =
        sine_interpolated(piano_phase_6_q);
    reg signed [16:0] piano_sine_1_q;
    reg signed [16:0] piano_sine_2_q;
    reg signed [16:0] piano_sine_3_q;
    reg signed [16:0] piano_sine_4_q;
    reg signed [16:0] piano_sine_5_q;
    reg signed [16:0] piano_sine_6_q;
    reg signed [19:0] piano_color_q;
    reg signed [19:0] piano_fundamental_q;
    reg signed [19:0] piano_fundamental_delay_q;
    reg signed [16:0] piano_hammer_q;
    reg signed [16:0] piano_hammer_delay_q;
    reg signed [16:0] piano_wave_pipeline;
    reg signed [16:0] organ_wave_pipeline;
    // The string spectrum must evolve after the hammer strike.  Upper
    // partials start strong, then step down over roughly one second; leaving
    // a fixed stretched partial for the whole note made low notes drone.
    wire signed [19:0] piano_sine_2_wide =
        {{3{piano_sine_2_q[16]}}, piano_sine_2_q};
    wire signed [19:0] piano_sine_3_wide =
        {{3{piano_sine_3_q[16]}}, piano_sine_3_q};
    wire signed [19:0] piano_sine_4_wide =
        {{3{piano_sine_4_q[16]}}, piano_sine_4_q};
    wire signed [19:0] piano_sine_5_wide =
        {{3{piano_sine_5_q[16]}}, piano_sine_5_q};
    wire signed [19:0] piano_sine_6_wide =
        {{3{piano_sine_6_q[16]}}, piano_sine_6_q};
    wire signed [19:0] piano_second_x3 =
        (piano_sine_2_wide <<< 1) + piano_sine_2_wide;
    wire signed [19:0] piano_fourth_x1_5 =
        piano_sine_4_wide + (piano_sine_4_wide >>> 1);
    wire signed [19:0] piano_sixth_x0_75 =
        (piano_sine_6_wide >>> 1) + (piano_sine_6_wide >>> 2);
    wire signed [19:0] piano_color_full_a =
        piano_second_x3 + (piano_sine_3_wide <<< 1);
    wire signed [19:0] piano_color_full_b =
        piano_fourth_x1_5 + piano_sine_5_wide;
    wire signed [19:0] piano_color_full_c =
        piano_color_full_b + piano_sixth_x0_75;
    wire signed [19:0] piano_color_full =
        piano_color_full_a + piano_color_full_c;
    wire signed [19:0] piano_color_mid_a =
        piano_sine_2_wide + (piano_sine_2_wide >>> 1) +
        piano_sine_3_wide;
    wire signed [19:0] piano_color_mid_b =
        (piano_sine_4_wide >>> 1) + (piano_sine_5_wide >>> 2) +
        (piano_sine_6_wide >>> 3);
    wire signed [19:0] piano_color_mid =
        piano_color_mid_a + piano_color_mid_b;
    wire signed [19:0] piano_color_low =
        (piano_sine_2_wide >>> 1) + (piano_sine_3_wide >>> 2) +
        (piano_sine_4_wide >>> 3);
    wire signed [19:0] piano_color_tail = piano_sine_2_wide >>> 3;
    // V7 changed harmonic weights in one sample at tone levels 192/128/64/0.
    // Interpolate over 16 levels (~84 ms) at each boundary so a piano note
    // does not acquire isolated zipper clicks while its timbre darkens.
    reg signed [19:0] piano_color_high;
    reg signed [19:0] piano_color_low_side;
    reg [4:0] piano_color_blend;
    reg signed [19:0] piano_color_high_q;
    reg signed [19:0] piano_color_low_side_q;
    reg [4:0] piano_color_blend_q;
    always @* begin
        piano_color_high = 20'sd0;
        piano_color_low_side = 20'sd0;
        piano_color_blend = 5'd0;
        if (piano_tone_level > 8'd192) begin
            piano_color_low_side = piano_color_full;
        end else if (piano_tone_level > 8'd176) begin
            piano_color_high = piano_color_full;
            piano_color_low_side = piano_color_mid;
            piano_color_blend = piano_tone_level[4:0] - 5'd16;
        end else if (piano_tone_level > 8'd128) begin
            piano_color_low_side = piano_color_mid;
        end else if (piano_tone_level > 8'd112) begin
            piano_color_high = piano_color_mid;
            piano_color_low_side = piano_color_low;
            piano_color_blend = piano_tone_level[4:0] - 5'd16;
        end else if (piano_tone_level > 8'd64) begin
            piano_color_low_side = piano_color_low;
        end else if (piano_tone_level > 8'd48) begin
            piano_color_high = piano_color_low;
            piano_color_low_side = piano_color_tail;
            piano_color_blend = piano_tone_level[4:0] - 5'd16;
        end else if (piano_tone_level > 8'd16) begin
            piano_color_low_side = piano_color_tail;
        end else begin
            piano_color_high = piano_color_tail;
            piano_color_blend = piano_tone_level[4:0];
        end
    end
    wire signed [20:0] piano_color_difference =
        {piano_color_high_q[19], piano_color_high_q} -
        {piano_color_low_side_q[19], piano_color_low_side_q};
    wire signed [26:0] piano_color_blend_product =
        piano_color_difference * $signed({1'b0, piano_color_blend_q});
    // The product is bounded by a 20-bit color difference times 16, so the
    // arithmetic /16 fits in 21 bits.  Slice explicitly to avoid truncation.
    wire signed [20:0] piano_color_blend_scaled =
        piano_color_blend_product[24:4];
    wire signed [20:0] piano_color_interpolated =
        {piano_color_low_side_q[19], piano_color_low_side_q} +
        piano_color_blend_scaled;
    wire signed [19:0] piano_color = piano_color_interpolated[19:0];
    // Explicit sign extension before x4 prevents 17-bit shift wraparound.
    wire signed [19:0] piano_fundamental_wide =
        {{3{piano_sine_1_q[16]}}, piano_sine_1_q};
    wire signed [19:0] piano_mix_wide =
        (piano_fundamental_delay_q <<< 2) + piano_color_q;
    // Reconstruct the documented V6 four-rank drawbar registration. This
    // sound was accepted by ear; spectral distance from piano is not a goal.
    // Reuse the already-registered sine values: phase -> sine interpolation
    // and four-rank mixing no longer share one 50 MHz combinational path.
    wire signed [18:0] organ_mix_wide =
        (piano_sine_1_q <<< 2) + piano_sine_2_q +
        (piano_sine_3_q >>> 1) + (piano_sine_4_q >>> 2);
    // Keep the organ contact transient aligned with the delayed sine ranks.
    reg signed [18:0] organ_mix_q;
    reg signed [16:0] organ_key_click_delay_q;
    reg signed [16:0] organ_key_click_q;
    wire signed [16:0] piano_raw = piano_mix_wide >>> 3;
    wire signed [16:0] piano_body =
        piano_raw - (piano_raw >>> 2) - (piano_raw >>> 3);
    // Independent ~10.5 ms hammer envelope. The old envelope_level>160 test
    // kept the "transient" alive for about half a second and sounded static.
    wire signed [16:0] piano_hammer =
        (strike_level > 8'd192) ?
            ((piano_sine_4_q >>> 2) + (piano_sine_5_q >>> 3) +
             (piano_sine_6_q >>> 3)) :
        (strike_level > 8'd128) ?
            ((piano_sine_4_q >>> 3) + (piano_sine_5_q >>> 4) +
             (piano_sine_6_q >>> 4)) :
        (strike_level > 8'd64) ? (piano_sine_4_q >>> 4) :
        (strike_level != 8'd0) ? (piano_sine_4_q >>> 5) : 17'sd0;
    wire signed [16:0] piano_wave_comb = piano_body + piano_hammer_delay_q;
    wire signed [16:0] organ_raw = organ_mix_q >>> 3;
    // Preserve the documented V6 13/16 oscillator balance. Loudness is
    // adjusted only after the complete organ wave and envelope are formed.
    wire signed [16:0] organ_body =
        organ_raw - (organ_raw >>> 3) - (organ_raw >>> 4);
    // The V6 contact transient lasts about 5 ms near the envelope crest.
    wire signed [16:0] organ_key_click =
        (envelope_level > 8'd240) ?
        (phase[28] ? 17'sd1800 : -17'sd1800) : 17'sd0;
    wire signed [16:0] organ_wave = organ_body + organ_key_click_q;
    wire signed [16:0] instrument_wave =
        voice_timbre ? organ_wave_pipeline : piano_wave_pipeline;
    wire signed [24:0] velocity_product =
        instrument_wave * $signed({1'b0, velocity});
    wire signed [32:0] envelope_product =
        velocity_product * $signed({1'b0, envelope_level});
    wire signed [32:0] scaled_sample = envelope_product >>> 15;
    // Isolated +3.5 dB organ output trim; do not retune the V6 oscillator.
    wire signed [32:0] gain_matched_sample = voice_timbre ?
        (scaled_sample + (scaled_sample >>> 1)) : scaled_sample;
    // Saturate instead of discarding upper bits.  A hard velocity strike can
    // briefly exceed 16-bit range; wraparound would turn the piano attack
    // into harsh digital noise.
    wire sample_positive_overflow =
        !gain_matched_sample[32] && (|gain_matched_sample[31:15]);
    wire sample_negative_overflow =
        gain_matched_sample[32] && !(&gain_matched_sample[31:15]);
    wire signed [15:0] saturated_sample = sample_positive_overflow ?
        16'sh7FFF : sample_negative_overflow ? 16'sh8000 :
        gain_matched_sample[15:0];

    function [31:0] note_phase_inc;
        input [6:0] midi_note;
        begin
            case (midi_note)
                7'd21: note_phase_inc = 32'd2418926;
                7'd22: note_phase_inc = 32'd2562762;
                7'd23: note_phase_inc = 32'd2715152;
                7'd24: note_phase_inc = 32'd2876604;
                7'd25: note_phase_inc = 32'd3047655;
                7'd26: note_phase_inc = 32'd3228878;
                7'd27: note_phase_inc = 32'd3420877;
                7'd28: note_phase_inc = 32'd3624293;
                7'd29: note_phase_inc = 32'd3839805;
                7'd30: note_phase_inc = 32'd4068132;
                7'd31: note_phase_inc = 32'd4310035;
                7'd32: note_phase_inc = 32'd4566323;
                7'd33: note_phase_inc = 32'd4837851;
                7'd34: note_phase_inc = 32'd5125525;
                7'd35: note_phase_inc = 32'd5430304;
                7'd36: note_phase_inc = 32'd5753207;
                7'd37: note_phase_inc = 32'd6095311;
                7'd38: note_phase_inc = 32'd6457757;
                7'd39: note_phase_inc = 32'd6841755;
                7'd40: note_phase_inc = 32'd7248587;
                7'd41: note_phase_inc = 32'd7679610;
                7'd42: note_phase_inc = 32'd8136263;
                7'd43: note_phase_inc = 32'd8620071;
                7'd44: note_phase_inc = 32'd9132647;
                7'd45: note_phase_inc = 32'd9675702;
                7'd46: note_phase_inc = 32'd10251050;
                7'd47: note_phase_inc = 32'd10860609;
                7'd48: note_phase_inc = 32'd11506414;
                7'd49: note_phase_inc = 32'd12190621;
                7'd50: note_phase_inc = 32'd12915513;
                7'd51: note_phase_inc = 32'd13683509;
                7'd52: note_phase_inc = 32'd14497173;
                7'd53: note_phase_inc = 32'd15359220;
                7'd54: note_phase_inc = 32'd16272527;
                7'd55: note_phase_inc = 32'd17240142;
                7'd56: note_phase_inc = 32'd18265294;
                7'd57: note_phase_inc = 32'd19351405;
                7'd58: note_phase_inc = 32'd20502099;
                7'd59: note_phase_inc = 32'd21721217;
                7'd60: note_phase_inc = 32'd23012828;
                7'd61: note_phase_inc = 32'd24381242;
                7'd62: note_phase_inc = 32'd25831026;
                7'd63: note_phase_inc = 32'd27367019;
                7'd64: note_phase_inc = 32'd28994347;
                7'd65: note_phase_inc = 32'd30718440;
                7'd66: note_phase_inc = 32'd32545054;
                7'd67: note_phase_inc = 32'd34480283;
                7'd68: note_phase_inc = 32'd36530588;
                7'd69: note_phase_inc = 32'd38702809;
                7'd70: note_phase_inc = 32'd41004198;
                7'd71: note_phase_inc = 32'd43442435;
                7'd72: note_phase_inc = 32'd46025656;
                7'd73: note_phase_inc = 32'd48762484;
                7'd74: note_phase_inc = 32'd51662052;
                7'd75: note_phase_inc = 32'd54734038;
                7'd76: note_phase_inc = 32'd57988693;
                7'd77: note_phase_inc = 32'd61436880;
                7'd78: note_phase_inc = 32'd65090107;
                7'd79: note_phase_inc = 32'd68960566;
                7'd80: note_phase_inc = 32'd73061175;
                7'd81: note_phase_inc = 32'd77405619;
                7'd82: note_phase_inc = 32'd82008396;
                7'd83: note_phase_inc = 32'd86884869;
                7'd84: note_phase_inc = 32'd92051312;
                7'd85: note_phase_inc = 32'd97524968;
                7'd86: note_phase_inc = 32'd103324105;
                7'd87: note_phase_inc = 32'd109468076;
                7'd88: note_phase_inc = 32'd115977386;
                7'd89: note_phase_inc = 32'd122873760;
                7'd90: note_phase_inc = 32'd130180214;
                7'd91: note_phase_inc = 32'd137921133;
                7'd92: note_phase_inc = 32'd146122350;
                7'd93: note_phase_inc = 32'd154811237;
                7'd94: note_phase_inc = 32'd164016792;
                7'd95: note_phase_inc = 32'd173769738;
                7'd96: note_phase_inc = 32'd184102625;
                7'd97: note_phase_inc = 32'd195049936;
                7'd98: note_phase_inc = 32'd206648209;
                7'd99: note_phase_inc = 32'd218936151;
                7'd100: note_phase_inc = 32'd231954772;
                7'd101: note_phase_inc = 32'd245747521;
                7'd102: note_phase_inc = 32'd260360429;
                7'd103: note_phase_inc = 32'd275842266;
                7'd104: note_phase_inc = 32'd292244700;
                7'd105: note_phase_inc = 32'd309622474;
                7'd106: note_phase_inc = 32'd328033585;
                7'd107: note_phase_inc = 32'd347539477;
                7'd108: note_phase_inc = 32'd368205249;
                default: note_phase_inc = 32'd23012828;
            endcase
        end
    endfunction

    // Pipeline the smooth color interpolation before the final body mix.
    // The extra 20 ns does not affect a human-scale note onset.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            piano_phase_3_q <= 32'd0;
            piano_phase_5_q <= 32'd0;
            piano_phase_6_q <= 32'd0;
            piano_sine_1_q <= 17'sd0;
            piano_sine_2_q <= 17'sd0;
            piano_sine_3_q <= 17'sd0;
            piano_sine_4_q <= 17'sd0;
            piano_sine_5_q <= 17'sd0;
            piano_sine_6_q <= 17'sd0;
            piano_color_high_q <= 20'sd0;
            piano_color_low_side_q <= 20'sd0;
            piano_color_blend_q <= 5'd0;
            piano_color_q <= 20'sd0;
            piano_fundamental_q <= 20'sd0;
            piano_fundamental_delay_q <= 20'sd0;
            piano_hammer_q <= 17'sd0;
            piano_hammer_delay_q <= 17'sd0;
            piano_wave_pipeline <= 17'sd0;
            organ_mix_q <= 19'sd0;
            organ_key_click_delay_q <= 17'sd0;
            organ_key_click_q <= 17'sd0;
            organ_wave_pipeline <= 17'sd0;
        end else begin
            piano_phase_3_q <= (phase << 1) + phase;
            piano_phase_5_q <= (phase << 2) + phase;
            piano_phase_6_q <= (phase << 2) + (phase << 1);
            piano_sine_1_q <= piano_sine_1;
            piano_sine_2_q <= piano_sine_2;
            piano_sine_3_q <= piano_sine_3;
            piano_sine_4_q <= piano_sine_4;
            piano_sine_5_q <= piano_sine_5;
            piano_sine_6_q <= piano_sine_6;
            piano_color_high_q <= piano_color_high;
            piano_color_low_side_q <= piano_color_low_side;
            piano_color_blend_q <= piano_color_blend;
            piano_color_q <= piano_color;
            piano_fundamental_q <= piano_fundamental_wide;
            piano_fundamental_delay_q <= piano_fundamental_q;
            piano_hammer_q <= piano_hammer;
            piano_hammer_delay_q <= piano_hammer_q;
            piano_wave_pipeline <= piano_wave_comb;
            organ_mix_q <= organ_mix_wide;
            organ_key_click_delay_q <= organ_key_click;
            organ_key_click_q <= organ_key_click_delay_q;
            organ_wave_pipeline <= organ_wave;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase          <= 32'd0;
            strike_level   <= 8'd0;
            strike_divider <= 3'd0;
            piano_tone_level <= 8'd0;
            piano_tone_divider <= 8'd0;
            envelope_level <= 8'd0;
            envelope_state <= ENV_IDLE;
            decay_divider  <= 11'd0;
            release_divider <= 5'd0;
            organ_hold_count <= 15'd0;
            voice_timbre <= 1'b0;
            audio_sample   <= 16'sd0;
            voice_finished <= 1'b0;
        end else begin
          voice_finished <= 1'b0;
          if (retrigger) begin
            phase          <= 32'd0;
            strike_level   <= {velocity, 1'b1};
            strike_divider <= 3'd0;
            piano_tone_level <= {velocity, 1'b1};
            piano_tone_divider <= 8'd0;
            envelope_level <= 8'd0;
            envelope_state <= ENV_ATTACK;
            decay_divider  <= 11'd0;
            release_divider <= 5'd0;
            organ_hold_count <= 15'd0;
            voice_timbre <= timbre_select;
          end else if (sample_tick) begin
            phase <= phase + phase_step_bent;
            if (strike_level != 8'd0) begin
                if (strike_divider == 3'd7) begin
                    strike_divider <= 3'd0;
                    if (strike_level > 8'd4)
                        strike_level <= strike_level - 8'd4;
                    else
                        strike_level <= 8'd0;
                end else begin
                    strike_divider <= strike_divider + 1'b1;
                end
            end
            if (piano_tone_level != 8'd0) begin
                if (piano_tone_divider == 8'd255) begin
                    piano_tone_divider <= 8'd0;
                    piano_tone_level <= piano_tone_level - 1'b1;
                end else begin
                    piano_tone_divider <= piano_tone_divider + 1'b1;
                end
            end
            audio_sample <= saturated_sample;

            case (envelope_state)
                ENV_IDLE: begin
                    envelope_level <= 8'd0;
                    decay_divider <= 11'd0;
                    release_divider <= 5'd0;
                    organ_hold_count <= 15'd0;
                end

                ENV_ATTACK: begin
                    if (!gate) begin
                        envelope_state <= ENV_RELEASE;
                        release_divider <= 5'd0;
                    end else if (envelope_level >= 8'd252) begin
                        envelope_level <= 8'hFF;
                        envelope_state <= ENV_DECAY;
                        decay_divider <= 11'd0;
                    end else begin
                        // Roughly 1.3 ms attack at 48.828125 kHz.
                        envelope_level <= envelope_level + 3'd4;
                    end
                end

                ENV_DECAY: begin
                    if (!gate) begin
                        envelope_state <= ENV_RELEASE;
                        release_divider <= 5'd0;
                    end else if (voice_timbre &&
                                 (envelope_level <= 8'd96)) begin
                        envelope_level <= 8'd96;
                        envelope_state <= ENV_ORGAN_HOLD;
                        decay_divider <= 11'd0;
                        organ_hold_count <= 15'd0;
                    end else if (voice_timbre &&
                                 (decay_divider == 11'd15)) begin
                        // V6-style ~52 ms settling to the held organ level.
                        decay_divider <= 11'd0;
                        envelope_level <= envelope_level - 1'b1;
                    end else if (voice_timbre) begin
                        decay_divider <= decay_divider + 1'b1;
                    end else if (envelope_level == 8'd0) begin
                        // Note On is a complete strike: after the tail, free
                        // this voice even when no Note Off was sent.
                        envelope_state <= ENV_IDLE;
                        decay_divider <= 11'd0;
                        voice_finished <= 1'b1;
                    end else if (((envelope_level > 8'd112) ||
                                  (note >= 7'd60)) &&
                                 (decay_divider == 11'd255)) begin
                        // Piano upper notes last about 1.34 s in total.
                        decay_divider <= 11'd0;
                        envelope_level <= envelope_level - 1'b1;
                    end else if ((note < 7'd60) &&
                                 (decay_divider == 11'd511)) begin
                        // Low notes keep a longer, naturally ending tail.
                        decay_divider <= 11'd0;
                        envelope_level <= envelope_level - 1'b1;
                    end else begin
                        decay_divider <= decay_divider + 1'b1;
                    end
                end

                ENV_ORGAN_HOLD: begin
                    if (!gate) begin
                        envelope_state <= ENV_RELEASE;
                        release_divider <= 5'd0;
                    end else if (organ_hold_count == 15'd29295) begin
                        // A 0.6 s organ-like plateau, then an automatic fade.
                        organ_hold_count <= 15'd0;
                        decay_divider <= 11'd0;
                        envelope_state <= ENV_ORGAN_FADE;
                    end else begin
                        organ_hold_count <= organ_hold_count + 1'b1;
                    end
                end

                ENV_ORGAN_FADE: begin
                    if (!gate) begin
                        envelope_state <= ENV_RELEASE;
                        release_divider <= 5'd0;
                    end else if (envelope_level == 8'd0) begin
                        envelope_state <= ENV_IDLE;
                        voice_finished <= 1'b1;
                    end else if (decay_divider == 11'd79) begin
                        // Fade the organ over about 0.24 s, without a click.
                        decay_divider <= 11'd0;
                        envelope_level <= envelope_level - 1'b1;
                    end else begin
                        decay_divider <= decay_divider + 1'b1;
                    end
                end

                ENV_RELEASE: begin
                    if (envelope_level == 8'd0) begin
                        envelope_state <= ENV_IDLE;
                        release_divider <= 5'd0;
                        voice_finished <= 1'b1;
                    end else if (release_divider == 5'd15) begin
                        // Full-scale release: at most about 83.6 ms.
                        release_divider <= 5'd0;
                        envelope_level <= envelope_level - 1'b1;
                    end else begin
                        release_divider <= release_divider + 1'b1;
                    end
                end

                default: begin
                    envelope_level <= 8'd0;
                    envelope_state <= ENV_IDLE;
                    decay_divider <= 11'd0;
                    release_divider <= 5'd0;
                end
            endcase
          end
        end
    end
endmodule
