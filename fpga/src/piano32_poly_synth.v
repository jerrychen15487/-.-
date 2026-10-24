// Four-voice piano, with one sine lookup and multiplier pipeline shared over
// 32 stretched partials per voice. The 4*32*6 partial cycles plus voice
// setup/output fit within one 1024-clock audio sample period at 50 MHz.
// The C4 spectrum is based on the 2026-10-17 comparison recording. Above C4,
// max_partial() suppresses out-of-band partials instead of aliasing them.
module piano32_poly_synth (
    input wire clk, rst_n, sample_tick, enable,
    input wire [127:0] step_bus,       // four bent DDS phase increments
    input wire [3:0] retrigger_bus,
    input wire [31:0] envelope_bus,   // four 8-bit envelopes
    input wire [27:0] velocity_bus,   // four 7-bit velocities
    input wire [27:0] note_bus,       // four 7-bit MIDI notes
    output reg signed [15:0] sample0, sample1, sample2, sample3,
    output reg sample_valid, overrun
);
    localparam [3:0] IDLE=0, LOAD=1, PHASE_READ=2, PHASE_CALC=3,
                     SINE=4, TONE=5, WEIGHT=6, ACCUM=7,
                     LEVEL=8, VELOCITY=9, OUTPUT=10;
    reg [3:0] state;
    reg [1:0] voice_index;
    reg [5:0] partial, partial_limit;
    reg [127:0] step_snapshot;
    reg [31:0] envelope_snapshot;
    reg [27:0] velocity_snapshot, note_snapshot;
    reg [31:0] step_current, phase_h_q, step_h_q;
    reg [3:0] reset_pending, reset_snapshot;
    reg previous_enable;
    reg [31:0] phase_mem [0:127];
    reg [31:0] phase_mem_rdata;
    wire [4:0] partial_address = partial[4:0] - 5'd1;
    wire [6:0] memory_address = {voice_index, partial_address};
    reg [7:0] envelope_current, tone_factor;
    reg [6:0] velocity_current;
    reg [15:0] weight_base_q, weight_q;
    reg signed [16:0] sine_q;
    reg signed [17:0] weighted_q;
    reg signed [31:0] sum_q;
    reg signed [39:0] level_product_q;
    reg signed [46:0] velocity_product_q;
    wire [53:0] step_product = step_current * harmonic_multiplier(partial);
    wire [23:0] tone_product = weight_base_q * tone_factor;
    wire signed [33:0] harmonic_product =
        $signed(sine_q) * $signed({1'b0, weight_q});
    wire signed [46:0] scaled = velocity_product_q >>> 15;
    wire signed [15:0] saturated =
        (scaled > 47'sd32767) ? 16'sh7fff :
        (scaled < -47'sd32768) ? 16'sh8000 : scaled[15:0];

    // Synchronous single-port memory: 128 independent partial phases. An
    // inharmonic oscillator must keep its own phase; multiplying the wrapped
    // fundamental phase would introduce a discontinuity every base period.
    always @(posedge clk) begin
        if (state == PHASE_READ) phase_mem_rdata <= phase_mem[memory_address];
        if (state == SINE) phase_mem[memory_address] <= phase_h_q + step_h_q;
    end

    // Q16 frequency multipliers implement f_n = n*f_1 *
    // sqrt((1+B*n*n)/(1+B)), with B=0.00035 measured at C4.
    function [21:0] harmonic_multiplier;
        input [5:0] n;
        begin
            case (n)
                6'd1: harmonic_multiplier=22'd65536;
                6'd2: harmonic_multiplier=22'd131141;
                6'd3: harmonic_multiplier=22'd196883;
                6'd4: harmonic_multiplier=22'd262831;
                6'd5: harmonic_multiplier=22'd329053;
                6'd6: harmonic_multiplier=22'd395616;
                6'd7: harmonic_multiplier=22'd462588;
                6'd8: harmonic_multiplier=22'd530035;
                6'd9: harmonic_multiplier=22'd598022;
                6'd10: harmonic_multiplier=22'd666614;
                6'd11: harmonic_multiplier=22'd735874;
                6'd12: harmonic_multiplier=22'd805865;
                6'd13: harmonic_multiplier=22'd876650;
                6'd14: harmonic_multiplier=22'd948286;
                6'd15: harmonic_multiplier=22'd1020835;
                6'd16: harmonic_multiplier=22'd1094353;
                6'd17: harmonic_multiplier=22'd1168897;
                6'd18: harmonic_multiplier=22'd1244521;
                6'd19: harmonic_multiplier=22'd1321278;
                6'd20: harmonic_multiplier=22'd1399221;
                6'd21: harmonic_multiplier=22'd1478400;
                6'd22: harmonic_multiplier=22'd1558864;
                6'd23: harmonic_multiplier=22'd1640659;
                6'd24: harmonic_multiplier=22'd1723833;
                6'd25: harmonic_multiplier=22'd1808428;
                6'd26: harmonic_multiplier=22'd1894488;
                6'd27: harmonic_multiplier=22'd1982054;
                6'd28: harmonic_multiplier=22'd2071166;
                6'd29: harmonic_multiplier=22'd2161861;
                6'd30: harmonic_multiplier=22'd2254177;
                6'd31: harmonic_multiplier=22'd2348150;
                default: harmonic_multiplier=22'd2443812;
            endcase
        end
    endfunction

    function [15:0] partial_weight;
        input [5:0] n;
        begin
            case (n)
                6'd1: partial_weight=16'd32768;
                6'd2: partial_weight=16'd10486;
                6'd3: partial_weight=16'd7209;
                6'd4: partial_weight=16'd5243;
                6'd5: partial_weight=16'd1311;
                6'd6: partial_weight=16'd5243;
                6'd7: partial_weight=16'd1638;
                6'd8: partial_weight=16'd819;
                6'd9: partial_weight=16'd4915;
                6'd10: partial_weight=16'd655;
                6'd11: partial_weight=16'd262;
                6'd12: partial_weight=16'd262;
                6'd13: partial_weight=16'd168;
                6'd14: partial_weight=16'd144;
                6'd15: partial_weight=16'd126;
                6'd16: partial_weight=16'd111;
                6'd17: partial_weight=16'd98;
                6'd18: partial_weight=16'd87;
                6'd19: partial_weight=16'd78;
                6'd20: partial_weight=16'd71;
                6'd21: partial_weight=16'd64;
                6'd22: partial_weight=16'd58;
                6'd23: partial_weight=16'd54;
                6'd24: partial_weight=16'd49;
                6'd25: partial_weight=16'd45;
                6'd26: partial_weight=16'd42;
                6'd27: partial_weight=16'd39;
                6'd28: partial_weight=16'd36;
                6'd29: partial_weight=16'd34;
                6'd30: partial_weight=16'd31;
                6'd31: partial_weight=16'd29;
                default: partial_weight=16'd28;
            endcase
        end
    endfunction

    // The audition used a common 0.23-radian base-phase offset. Convert it
    // once per partial to avoid a second multiplier in the live path.
    function [31:0] phase_offset;
        input [5:0] n;
        begin
            case (n)
                6'd1: phase_offset=32'd157206000;
                6'd2: phase_offset=32'd314577515;
                6'd3: phase_offset=32'd472277662;
                6'd4: phase_offset=32'd630471957;
                6'd5: phase_offset=32'd789323515;
                6'd6: phase_offset=32'd948993055;
                6'd7: phase_offset=32'd1109643693;
                6'd8: phase_offset=32'd1271433749;
                6'd9: phase_offset=32'd1434519142;
                6'd10: phase_offset=32'd1599055793;
                6'd11: phase_offset=32'd1765194824;
                6'd12: phase_offset=32'd1933087359;
                6'd13: phase_offset=32'd2102884519;
                6'd14: phase_offset=32'd2274723036;
                6'd15: phase_offset=32'd2448751632;
                6'd16: phase_offset=32'd2625104640;
                6'd17: phase_offset=32'd2803918789;
                6'd18: phase_offset=32'd2985323613;
                6'd19: phase_offset=32'd3169446247;
                6'd20: phase_offset=32'd3356413826;
                6'd21: phase_offset=32'd3546346289;
                6'd22: phase_offset=32'd3739361175;
                6'd23: phase_offset=32'd3935568828;
                6'd24: phase_offset=32'd4135084390;
                6'd25: phase_offset=32'd43041312;
                6'd26: phase_offset=32'd249479733;
                6'd27: phase_offset=32'd459530706;
                6'd28: phase_offset=32'd673290183;
                6'd29: phase_offset=32'd890846918;
                6'd30: phase_offset=32'd1112292064;
                6'd31: phase_offset=32'd1337711977;
                default: phase_offset=32'd1567183419;
            endcase
        end
    endfunction

    // Conservative 24 kHz band limit at the project's 48.828 kHz rate.
    function [5:0] max_partial;
        input [6:0] note;
        begin
            if (note <= 7'd75) max_partial=6'd32;
            else if (note == 7'd76) max_partial=6'd31;
            else if (note == 7'd77) max_partial=6'd29;
            else if (note == 7'd78) max_partial=6'd28;
            else if (note == 7'd79) max_partial=6'd27;
            else if (note == 7'd80) max_partial=6'd25;
            else if (note == 7'd81) max_partial=6'd24;
            else if (note == 7'd82) max_partial=6'd23;
            else if (note == 7'd83) max_partial=6'd22;
            else if (note == 7'd84) max_partial=6'd21;
            else if (note == 7'd85) max_partial=6'd20;
            else if (note == 7'd86) max_partial=6'd19;
            else if (note == 7'd87) max_partial=6'd18;
            else if (note == 7'd88) max_partial=6'd17;
            else if (note == 7'd89) max_partial=6'd16;
            else if (note == 7'd90) max_partial=6'd15;
            else if (note == 7'd91) max_partial=6'd14;
            else if (note <= 7'd93) max_partial=6'd13;
            else if (note == 7'd94) max_partial=6'd12;
            else if (note <= 7'd96) max_partial=6'd11;
            else if (note <= 7'd98) max_partial=6'd10;
            else if (note == 7'd99) max_partial=6'd9;
            else if (note <= 7'd102) max_partial=6'd8;
            else if (note <= 7'd104) max_partial=6'd7;
            else if (note <= 7'd107) max_partial=6'd6;
            else max_partial=6'd5;
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
            quarter_index=address[4] ? (5'd16-{1'b0,address[3:0]}) :
                                        {1'b0,address[3:0]};
            magnitude=quarter_sine(quarter_index);
            sine64=address[5] ? -magnitude : magnitude;
        end
    endfunction

    function signed [16:0] sine_interpolated;
        input [31:0] angle;
        reg signed [16:0] a,b;
        reg signed [17:0] delta;
        reg signed [28:0] product;
        reg signed [17:0] result;
        begin
            a=sine64(angle[31:26]);
            b=sine64(angle[31:26]+6'd1);
            delta=$signed({b[16],b})-$signed({a[16],a});
            product=delta*$signed({1'b0,angle[25:16]});
            result=$signed({a[16],a})+(product >>> 10);
            sine_interpolated=result[16:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; voice_index<=0; partial<=0; partial_limit<=0;
            step_snapshot<=0; envelope_snapshot<=0;
            velocity_snapshot<=0; note_snapshot<=0;
            step_current<=0; phase_h_q<=0; step_h_q<=0;
            reset_pending<=4'b1111; reset_snapshot<=0;
            previous_enable<=0;
            envelope_current<=0; velocity_current<=0; tone_factor<=0;
            weight_base_q<=0; weight_q<=0; sine_q<=0; weighted_q<=0;
            sum_q<=0; level_product_q<=0; velocity_product_q<=0;
            sample0<=0; sample1<=0; sample2<=0; sample3<=0;
            sample_valid<=0; overrun<=0;
        end else begin
            sample_valid<=0;
            if (|retrigger_bus) reset_pending<=reset_pending | retrigger_bus;
            if (sample_tick) begin
                if (state != IDLE) overrun<=1;
                previous_enable<=enable;
                if (enable) begin
                    step_snapshot<=step_bus;
                    envelope_snapshot<=envelope_bus;
                    velocity_snapshot<=velocity_bus;
                    note_snapshot<=note_bus;
                    reset_snapshot<=!previous_enable ? 4'b1111 :
                                    (reset_pending | retrigger_bus);
                    reset_pending<=0;
                    voice_index<=0;
                    state<=LOAD;
                end else begin
                    sample0<=0; sample1<=0; sample2<=0; sample3<=0;
                    state<=IDLE;
                end
            end else begin
                case (state)
                    LOAD: begin
                        case (voice_index)
                            2'd0: begin
                                step_current<=step_snapshot[31:0];
                                envelope_current<=envelope_snapshot[7:0];
                                velocity_current<=velocity_snapshot[6:0];
                                partial_limit<=max_partial(note_snapshot[6:0]);
                            end
                            2'd1: begin
                                step_current<=step_snapshot[63:32];
                                envelope_current<=envelope_snapshot[15:8];
                                velocity_current<=velocity_snapshot[13:7];
                                partial_limit<=max_partial(note_snapshot[13:7]);
                            end
                            2'd2: begin
                                step_current<=step_snapshot[95:64];
                                envelope_current<=envelope_snapshot[23:16];
                                velocity_current<=velocity_snapshot[20:14];
                                partial_limit<=max_partial(note_snapshot[20:14]);
                            end
                            default: begin
                                step_current<=step_snapshot[127:96];
                                envelope_current<=envelope_snapshot[31:24];
                                velocity_current<=velocity_snapshot[27:21];
                                partial_limit<=max_partial(note_snapshot[27:21]);
                            end
                        endcase
                        partial<=6'd1;
                        sum_q<=0;
                        state<=PHASE_READ;
                    end
                    PHASE_READ: state<=PHASE_CALC;
                    PHASE_CALC: begin
                        phase_h_q<=reset_snapshot[voice_index] ?
                                   phase_offset(partial) : phase_mem_rdata;
                        step_h_q<=step_product[47:16];
                        weight_base_q<=partial_weight(partial);
                        state<=SINE;
                    end
                    SINE: begin
                        sine_q<=sine_interpolated(phase_h_q);
                        if (partial<=6'd4) tone_factor<=8'd255;
                        else if (partial==6'd6 || partial==6'd9)
                            tone_factor<=8'd192+(envelope_current>>2);
                        else if (partial>=6'd13) tone_factor<=envelope_current;
                        else tone_factor<=8'd63+envelope_current-(envelope_current>>2);
                        state<=TONE;
                    end
                    TONE: begin
                        weight_q<=tone_product[23:8];
                        state<=WEIGHT;
                    end
                    WEIGHT: begin
                        weighted_q<=harmonic_product >>> 15;
                        state<=ACCUM;
                    end
                    ACCUM: begin
                        sum_q<=sum_q+weighted_q;
                        if (partial==partial_limit) state<=LEVEL;
                        else begin partial<=partial+1'b1; state<=PHASE_READ; end
                    end
                    LEVEL: begin
                        level_product_q<=(sum_q >>> 2)*$signed({1'b0,envelope_current});
                        state<=VELOCITY;
                    end
                    VELOCITY: begin
                        velocity_product_q<=level_product_q*$signed({1'b0,velocity_current});
                        state<=OUTPUT;
                    end
                    OUTPUT: begin
                        case (voice_index)
                            2'd0: sample0<=saturated;
                            2'd1: sample1<=saturated;
                            2'd2: sample2<=saturated;
                            default: sample3<=saturated;
                        endcase
                        if (voice_index==2'd3) begin
                            sample_valid<=1;
                            state<=IDLE;
                        end else begin
                            voice_index<=voice_index+1'b1;
                            state<=LOAD;
                        end
                    end
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
