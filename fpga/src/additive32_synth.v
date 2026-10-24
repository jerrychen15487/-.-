// One-note, 32-partial real-time additive engine. One sine/interpolator and
// multiplier are reused over 32 partials within each 1024-clock audio frame.
// This is an optional timbre, not 32-note polyphony. The top limits notes to
// MIDI 76 so harmonic 32 remains below Nyquist even at maximum bend/vibrato.
module additive32_synth (
    input wire clk, rst_n, sample_tick, enable,
    input wire [31:0] phase,
    input wire [7:0] envelope,
    input wire [6:0] velocity,
    output reg signed [15:0] audio_sample,
    output reg sample_valid,
    output reg overrun
);
    localparam [3:0] IDLE=4'd0, PHASE=4'd1, SINE_PREP=4'd2,
                     SINE_INTERP=4'd3, WEIGHT=4'd4, ACCUM=4'd5,
                     LEVEL=4'd6, VELOCITY=4'd7, OUTPUT=4'd8;
    reg [3:0] state;
    reg [5:0] partial;
    reg [31:0] phase_snapshot, phase_h_q;
    reg [7:0] envelope_snapshot;
    reg [6:0] velocity_snapshot;
    reg [15:0] weight_q;
    reg signed [16:0] sine_q;
    reg signed [16:0] sine_a_q, sine_b_q;
    reg [9:0] sine_fraction_q;
    wire signed [17:0] sine_delta =
        $signed({sine_b_q[16], sine_b_q}) -
        $signed({sine_a_q[16], sine_a_q});
    wire signed [28:0] sine_product =
        sine_delta * $signed({1'b0, sine_fraction_q});
    wire signed [17:0] sine_result =
        $signed({sine_a_q[16], sine_a_q}) + (sine_product >>> 10);
    reg signed [17:0] weighted_q;
    wire signed [33:0] harmonic_product =
        $signed(sine_q)*$signed({1'b0,weight_q});
    reg signed [31:0] sum_q;
    reg signed [39:0] level_product_q;
    reg signed [46:0] velocity_product_q;
    wire signed [46:0] scaled = velocity_product_q >>> 15;

    function [15:0] partial_weight;
        input [5:0] n;
        begin
            case(n)
                6'd1:partial_weight=16'd32768; 6'd2:partial_weight=16'd16384;
                6'd3:partial_weight=16'd10923; 6'd4:partial_weight=16'd8192;
                6'd5:partial_weight=16'd6554; 6'd6:partial_weight=16'd5461;
                6'd7:partial_weight=16'd4681; 6'd8:partial_weight=16'd4096;
                6'd9:partial_weight=16'd3641; 6'd10:partial_weight=16'd3277;
                6'd11:partial_weight=16'd2979; 6'd12:partial_weight=16'd2731;
                6'd13:partial_weight=16'd2521; 6'd14:partial_weight=16'd2341;
                6'd15:partial_weight=16'd2185; 6'd16:partial_weight=16'd2048;
                6'd17:partial_weight=16'd1928; 6'd18:partial_weight=16'd1820;
                6'd19:partial_weight=16'd1725; 6'd20:partial_weight=16'd1638;
                6'd21:partial_weight=16'd1560; 6'd22:partial_weight=16'd1489;
                6'd23:partial_weight=16'd1425; 6'd24:partial_weight=16'd1365;
                6'd25:partial_weight=16'd1311; 6'd26:partial_weight=16'd1260;
                6'd27:partial_weight=16'd1214; 6'd28:partial_weight=16'd1170;
                6'd29:partial_weight=16'd1130; 6'd30:partial_weight=16'd1092;
                6'd31:partial_weight=16'd1057; default:partial_weight=16'd1024;
            endcase
        end
    endfunction

    function signed [16:0] quarter_sine;
        input [4:0] index;
        begin
            case(index)
                5'd0:quarter_sine=17'sd0; 5'd1:quarter_sine=17'sd3212;
                5'd2:quarter_sine=17'sd6393; 5'd3:quarter_sine=17'sd9512;
                5'd4:quarter_sine=17'sd12539; 5'd5:quarter_sine=17'sd15446;
                5'd6:quarter_sine=17'sd18204; 5'd7:quarter_sine=17'sd20787;
                5'd8:quarter_sine=17'sd23170; 5'd9:quarter_sine=17'sd25329;
                5'd10:quarter_sine=17'sd27245; 5'd11:quarter_sine=17'sd28898;
                5'd12:quarter_sine=17'sd30273; 5'd13:quarter_sine=17'sd31356;
                5'd14:quarter_sine=17'sd32137; 5'd15:quarter_sine=17'sd32609;
                default:quarter_sine=17'sd32767;
            endcase
        end
    endfunction

    function signed [16:0] sine64;
        input [5:0] address;
        reg signed [16:0] magnitude;
        reg [4:0] quarter_index;
        begin
            quarter_index = address[4] ? (5'd16-{1'b0,address[3:0]}) :
                                          {1'b0,address[3:0]};
            magnitude = quarter_sine(quarter_index);
            sine64 = address[5] ? -magnitude : magnitude;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; partial<=0; phase_snapshot<=0; phase_h_q<=0;
            envelope_snapshot<=0; velocity_snapshot<=0; weight_q<=0;
            sine_q<=0; sine_a_q<=0; sine_b_q<=0; sine_fraction_q<=0;
            weighted_q<=0; sum_q<=0; level_product_q<=0;
            velocity_product_q<=0; audio_sample<=0; sample_valid<=0;
            overrun<=0;
        end else begin
            sample_valid<=0;
            if (sample_tick) begin
                if (state != IDLE) overrun<=1;
                if (enable) begin
                    phase_snapshot<=phase;
                    envelope_snapshot<=envelope;
                    velocity_snapshot<=velocity;
                    partial<=6'd1;
                    sum_q<=0;
                    state<=PHASE;
                end else begin
                    audio_sample<=0;
                    state<=IDLE;
                end
            end else begin
                case(state)
                    PHASE: begin
                        phase_h_q<=phase_snapshot*partial;
                        weight_q<=partial_weight(partial);
                        state<=SINE_PREP;
                    end
                    SINE_PREP: begin
                        sine_a_q<=sine64(phase_h_q[31:26]);
                        sine_b_q<=sine64(phase_h_q[31:26]+6'd1);
                        sine_fraction_q<=phase_h_q[25:16];
                        state<=SINE_INTERP;
                    end
                    SINE_INTERP: begin
                        sine_q<=sine_result[16:0];
                        state<=WEIGHT;
                    end
                    WEIGHT: begin
                        weighted_q<=harmonic_product >>> 15;
                        state<=ACCUM;
                    end
                    ACCUM: begin
                        sum_q<=sum_q+weighted_q;
                        if (partial==6'd32) state<=LEVEL;
                        else begin partial<=partial+1'b1; state<=PHASE; end
                    end
                    LEVEL: begin
                        level_product_q<=(sum_q >>> 2)*$signed({1'b0,envelope_snapshot});
                        state<=VELOCITY;
                    end
                    VELOCITY: begin
                        velocity_product_q<=level_product_q*$signed({1'b0,velocity_snapshot});
                        state<=OUTPUT;
                    end
                    OUTPUT: begin
                        audio_sample <= (scaled > 47'sd32767) ? 16'sh7fff :
                                        (scaled < -47'sd32768) ? 16'sh8000 :
                                        scaled[15:0];
                        sample_valid<=1;
                        state<=IDLE;
                    end
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
