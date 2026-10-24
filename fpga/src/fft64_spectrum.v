// 64-point radix-2 FFT spectrum analyzer.
//
// Audio samples are captured in bit-reversed order. Six in-place DIT stages
// then produce bins 0..31 in natural order. One shared complex butterfly is
// reused, keeping the design small; all 192 butterflies and 32 magnitude
// conversions finish well before the next 48.8 kHz sample arrives.
module fft64_spectrum (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                sample_tick,
    input  wire signed [15:0]  audio_sample,
    output wire [255:0]        magnitude_bus,
    output reg                 update_toggle
);
    localparam [2:0] STATE_CAPTURE   = 3'd0;
    localparam [2:0] STATE_FFT_READ  = 3'd1;
    localparam [2:0] STATE_FFT_WRITE = 3'd2;
    localparam [2:0] STATE_MAG_READ  = 3'd3;
    localparam [2:0] STATE_MAG_WRITE = 3'd4;

    reg signed [23:0] real_mem [0:63];
    reg signed [23:0] imag_mem [0:63];
    reg [2:0] state;
    reg [5:0] capture_index;
    reg [3:0] decimation_counter;
    reg signed [20:0] decimation_sum;
    reg [2:0] stage;
    reg [5:0] group_base;
    reg [5:0] butterfly_j;
    reg [5:0] magnitude_index;
    reg [31:0] magnitude_write_onehot;
    reg [7:0] magnitude_register [0:31];
    reg [5:0] fft_index_a_q;
    reg [5:0] fft_index_b_q;
    reg signed [23:0] fft_a_real_q;
    reg signed [23:0] fft_a_imag_q;
    reg signed [23:0] fft_b_real_q;
    reg signed [23:0] fft_b_imag_q;
    reg signed [15:0] fft_tw_cos_q;
    reg signed [15:0] fft_tw_sin_q;
    reg signed [23:0] mag_real_q;
    reg signed [23:0] mag_imag_q;
    integer reset_index;
    integer magnitude_write_index;
    genvar pack_index;

    generate
        for (pack_index = 0; pack_index < 32; pack_index = pack_index + 1) begin: pack_magnitudes
            assign magnitude_bus[(pack_index * 8) +: 8] = magnitude_register[pack_index];
        end
    endgenerate

    function [5:0] reverse6;
        input [5:0] value;
        begin
            reverse6 = {value[0], value[1], value[2],
                        value[3], value[4], value[5]};
        end
    endfunction

    function signed [15:0] twiddle_cos;
        input [4:0] index;
        begin
            case (index)
                5'd0:  twiddle_cos= 16'sd16384; 5'd1:  twiddle_cos= 16'sd16305;
                5'd2:  twiddle_cos= 16'sd16069; 5'd3:  twiddle_cos= 16'sd15679;
                5'd4:  twiddle_cos= 16'sd15137; 5'd5:  twiddle_cos= 16'sd14449;
                5'd6:  twiddle_cos= 16'sd13623; 5'd7:  twiddle_cos= 16'sd12665;
                5'd8:  twiddle_cos= 16'sd11585; 5'd9:  twiddle_cos= 16'sd10394;
                5'd10: twiddle_cos= 16'sd9102;  5'd11: twiddle_cos= 16'sd7723;
                5'd12: twiddle_cos= 16'sd6270;  5'd13: twiddle_cos= 16'sd4756;
                5'd14: twiddle_cos= 16'sd3196;  5'd15: twiddle_cos= 16'sd1606;
                5'd16: twiddle_cos= 16'sd0;     5'd17: twiddle_cos=-16'sd1606;
                5'd18: twiddle_cos=-16'sd3196; 5'd19: twiddle_cos=-16'sd4756;
                5'd20: twiddle_cos=-16'sd6270; 5'd21: twiddle_cos=-16'sd7723;
                5'd22: twiddle_cos=-16'sd9102; 5'd23: twiddle_cos=-16'sd10394;
                5'd24: twiddle_cos=-16'sd11585;5'd25: twiddle_cos=-16'sd12665;
                5'd26: twiddle_cos=-16'sd13623;5'd27: twiddle_cos=-16'sd14449;
                5'd28: twiddle_cos=-16'sd15137;5'd29: twiddle_cos=-16'sd15679;
                5'd30: twiddle_cos=-16'sd16069;default: twiddle_cos=-16'sd16305;
            endcase
        end
    endfunction

    function signed [15:0] twiddle_sin;
        input [4:0] index;
        begin
            case (index)
                5'd0:  twiddle_sin= 16'sd0;      5'd1:  twiddle_sin=-16'sd1606;
                5'd2:  twiddle_sin=-16'sd3196;  5'd3:  twiddle_sin=-16'sd4756;
                5'd4:  twiddle_sin=-16'sd6270;  5'd5:  twiddle_sin=-16'sd7723;
                5'd6:  twiddle_sin=-16'sd9102;  5'd7:  twiddle_sin=-16'sd10394;
                5'd8:  twiddle_sin=-16'sd11585; 5'd9:  twiddle_sin=-16'sd12665;
                5'd10: twiddle_sin=-16'sd13623; 5'd11: twiddle_sin=-16'sd14449;
                5'd12: twiddle_sin=-16'sd15137; 5'd13: twiddle_sin=-16'sd15679;
                5'd14: twiddle_sin=-16'sd16069; 5'd15: twiddle_sin=-16'sd16305;
                5'd16: twiddle_sin=-16'sd16384; 5'd17: twiddle_sin=-16'sd16305;
                5'd18: twiddle_sin=-16'sd16069; 5'd19: twiddle_sin=-16'sd15679;
                5'd20: twiddle_sin=-16'sd15137; 5'd21: twiddle_sin=-16'sd14449;
                5'd22: twiddle_sin=-16'sd13623; 5'd23: twiddle_sin=-16'sd12665;
                5'd24: twiddle_sin=-16'sd11585; 5'd25: twiddle_sin=-16'sd10394;
                5'd26: twiddle_sin=-16'sd9102;  5'd27: twiddle_sin=-16'sd7723;
                5'd28: twiddle_sin=-16'sd6270;  5'd29: twiddle_sin=-16'sd4756;
                5'd30: twiddle_sin=-16'sd3196;  default: twiddle_sin=-16'sd1606;
            endcase
        end
    endfunction

    wire [6:0] half_size = 7'd1 << stage;
    wire [6:0] fft_size  = 7'd2 << stage;
    wire [6:0] index_a_wide = {1'b0, group_base} + {1'b0, butterfly_j};
    wire [6:0] index_b_wide = index_a_wide + half_size;
    wire [5:0] index_a = index_a_wide[5:0];
    wire [5:0] index_b = index_b_wide[5:0];
    wire [5:0] twiddle_index_wide = butterfly_j << (3'd5 - stage);
    wire [4:0] twiddle_index = twiddle_index_wide[4:0];

    wire signed [23:0] a_real = real_mem[index_a];
    wire signed [23:0] a_imag = imag_mem[index_a];
    wire signed [23:0] b_real = real_mem[index_b];
    wire signed [23:0] b_imag = imag_mem[index_b];
    wire signed [15:0] tw_cos = twiddle_cos(twiddle_index);
    wire signed [15:0] tw_sin = twiddle_sin(twiddle_index);
    wire signed [39:0] mul_rc = fft_b_real_q * fft_tw_cos_q;
    wire signed [39:0] mul_is = fft_b_imag_q * fft_tw_sin_q;
    wire signed [39:0] mul_rs = fft_b_real_q * fft_tw_sin_q;
    wire signed [39:0] mul_ic = fft_b_imag_q * fft_tw_cos_q;
    wire signed [40:0] product_real = $signed({mul_rc[39],mul_rc}) -
                                      $signed({mul_is[39],mul_is});
    wire signed [40:0] product_imag = $signed({mul_rs[39],mul_rs}) +
                                      $signed({mul_ic[39],mul_ic});
    wire signed [23:0] rotated_real = product_real[37:14];
    wire signed [23:0] rotated_imag = product_imag[37:14];

    wire signed [23:0] mag_real_value = mag_real_q;
    wire signed [23:0] mag_imag_value = mag_imag_q;
    wire [23:0] abs_real = mag_real_value[23] ?
                           (~mag_real_value + 1'b1) : mag_real_value;
    wire [23:0] abs_imag = mag_imag_value[23] ?
                           (~mag_imag_value + 1'b1) : mag_imag_value;
    // Low-cost magnitude estimate. The FFT itself remains a true complex FFT.
    wire [24:0] magnitude_approx = {1'b0, abs_real} +
                                   {2'b0, abs_imag[23:1]};
    // Four-times more display gain than the first FFT version. The previous
    // >>12 scaling made normal velocity-100 notes only a few pixels high.
    wire [14:0] magnitude_scaled = magnitude_approx[24:10];
    wire [7:0] magnitude_clamped = |magnitude_scaled[14:8] ?
                                   8'hFF : magnitude_scaled[7:0];
    wire signed [20:0] decimation_sum_next = decimation_sum +
                                             {{5{audio_sample[15]}}, audio_sample};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= STATE_CAPTURE;
            capture_index   <= 6'd0;
            decimation_counter <= 4'd0;
            decimation_sum <= 21'sd0;
            stage           <= 3'd0;
            group_base      <= 6'd0;
            butterfly_j     <= 6'd0;
            magnitude_index <= 6'd0;
            magnitude_write_onehot <= 32'd0;
            update_toggle   <= 1'b0;
            fft_index_a_q   <= 6'd0;
            fft_index_b_q   <= 6'd0;
            fft_a_real_q    <= 24'sd0;
            fft_a_imag_q    <= 24'sd0;
            fft_b_real_q    <= 24'sd0;
            fft_b_imag_q    <= 24'sd0;
            fft_tw_cos_q    <= 16'sd0;
            fft_tw_sin_q    <= 16'sd0;
            mag_real_q      <= 24'sd0;
            mag_imag_q      <= 24'sd0;
            for (reset_index = 0; reset_index < 64; reset_index = reset_index + 1) begin
                real_mem[reset_index] <= 24'sd0;
                imag_mem[reset_index] <= 24'sd0;
            end
            for (reset_index = 0; reset_index < 32; reset_index = reset_index + 1)
                magnitude_register[reset_index] <= 8'd0;
        end else begin
            case (state)
                STATE_CAPTURE: begin
                    if (sample_tick) begin
                        // Average 16 input samples before each FFT sample.
                        // This boxcar low-pass + decimation concentrates the
                        // display on 0..1.526 kHz with 47.68 Hz/bin, allowing
                        // the four 261/331/393/521 Hz test tones to separate.
                        if (decimation_counter == 4'd15) begin
                            decimation_counter <= 4'd0;
                            decimation_sum <= 21'sd0;
                            real_mem[reverse6(capture_index)] <=
                                {{7{decimation_sum_next[20]}}, decimation_sum_next[20:4]};
                            imag_mem[reverse6(capture_index)] <= 24'sd0;
                            if (capture_index == 6'd63) begin
                                capture_index <= 6'd0;
                                stage         <= 3'd0;
                                group_base    <= 6'd0;
                                butterfly_j   <= 6'd0;
                                state         <= STATE_FFT_READ;
                            end else begin
                                capture_index <= capture_index + 1'b1;
                            end
                        end else begin
                            decimation_counter <= decimation_counter + 1'b1;
                            decimation_sum <= decimation_sum_next;
                        end
                    end
                end

                STATE_FFT_READ: begin
                    // Address decode and memory read get their own cycle.
                    // This removes the variable-index read from the same
                    // 50 MHz path as the twiddle multipliers and writeback.
                    fft_index_a_q <= index_a;
                    fft_index_b_q <= index_b;
                    fft_a_real_q <= a_real;
                    fft_a_imag_q <= a_imag;
                    fft_b_real_q <= b_real;
                    fft_b_imag_q <= b_imag;
                    fft_tw_cos_q <= tw_cos;
                    fft_tw_sin_q <= tw_sin;
                    state <= STATE_FFT_WRITE;
                end

                STATE_FFT_WRITE: begin
                    real_mem[fft_index_a_q] <= fft_a_real_q + rotated_real;
                    imag_mem[fft_index_a_q] <= fft_a_imag_q + rotated_imag;
                    real_mem[fft_index_b_q] <= fft_a_real_q - rotated_real;
                    imag_mem[fft_index_b_q] <= fft_a_imag_q - rotated_imag;

                    if ({1'b0, butterfly_j} == (half_size - 1'b1)) begin
                        butterfly_j <= 6'd0;
                        if (({1'b0, group_base} + fft_size) >= 7'd64) begin
                            group_base <= 6'd0;
                            if (stage == 3'd5) begin
                                magnitude_index <= 6'd0;
                                magnitude_write_onehot <= 32'd1;
                                state <= STATE_MAG_READ;
                            end else begin
                                stage <= stage + 1'b1;
                                state <= STATE_FFT_READ;
                            end
                        end else begin
                            group_base <= group_base + fft_size[5:0];
                            state <= STATE_FFT_READ;
                        end
                    end else begin
                        butterfly_j <= butterfly_j + 1'b1;
                        state <= STATE_FFT_READ;
                    end
                end

                STATE_MAG_READ: begin
                    mag_real_q <= real_mem[magnitude_index];
                    mag_imag_q <= imag_mem[magnitude_index];
                    state <= STATE_MAG_WRITE;
                end

                STATE_MAG_WRITE: begin
                    for (magnitude_write_index = 0; magnitude_write_index < 32;
                         magnitude_write_index = magnitude_write_index + 1)
                        if (magnitude_write_onehot[magnitude_write_index])
                            magnitude_register[magnitude_write_index] <= magnitude_clamped;
                    if (magnitude_index == 6'd31) begin
                        magnitude_index <= 6'd0;
                        magnitude_write_onehot <= 32'd0;
                        update_toggle <= ~update_toggle;
                        state <= STATE_CAPTURE;
                    end else begin
                        magnitude_index <= magnitude_index + 1'b1;
                        magnitude_write_onehot <= {magnitude_write_onehot[30:0], 1'b0};
                        state <= STATE_MAG_READ;
                    end
                end

                default: state <= STATE_CAPTURE;
            endcase
        end
    end
endmodule
