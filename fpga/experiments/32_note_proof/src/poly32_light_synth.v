// Optional 32-note proof mode. One arithmetic lane visits 32 independent
// phase/envelope records in 192 system clocks per audio sample (1024 budget).
// This is deliberately separate from the four-voice, 32-partial piano preset.
module poly32_light_synth (
    input wire clk, rst_n, sample_tick,
    input wire frame_valid,
    input wire [7:0] event_type, data1, data2,
    input wire [15:0] bend_factor_q14,
    output reg signed [15:0] audio_sample,
    output reg sample_valid,
    output reg [5:0] active_count
);
    reg [6:0] note_mem [0:31];
    reg [6:0] velocity_mem [0:31];
    reg [31:0] step_mem [0:31];
    reg [31:0] phase_mem [0:31];
    reg [7:0] env_mem [0:31];
    reg [3:0] release_div [0:31];
    reg [31:0] gate_bits, key_bits;
    reg sustain_on;
    reg [4:0] steal_ptr;
    reg [4:0] scan_idx;
    reg [2:0] scan_stage;
    reg scanning;
    reg [31:0] phase_q, step_q;
    reg [6:0] velocity_q;
    reg [7:0] env_q;
    reg [47:0] step_product_q;
    reg signed [15:0] wave_q;
    reg signed [23:0] velocity_product_q;
    reg signed [31:0] contribution_q;
    reg signed [23:0] mix_acc;
    reg [5:0] scan_count;
    wire [3:0] gain_shift = (scan_count<=1) ? 4'd4 :
                            (scan_count<=2) ? 4'd3 :
                            (scan_count<=4) ? 4'd2 :
                            (scan_count<=8) ? 4'd1 : 4'd0;
    integer j, s;

    // Shared lookup: one octave of increments, shifted to MIDI 21..108.
    function [31:0] note_step;
        input [6:0] n;
        reg [6:0] reference_note;
        reg [31:0] base;
        begin
            if (n < 7'd21 || n > 7'd108) reference_note = 7'd60;
            else if (n < 7'd24) reference_note = n + 7'd48;
            else if (n < 7'd36) reference_note = n + 7'd36;
            else if (n < 7'd48) reference_note = n + 7'd24;
            else if (n < 7'd60) reference_note = n + 7'd12;
            else if (n < 7'd72) reference_note = n;
            else if (n < 7'd84) reference_note = n - 7'd12;
            else if (n < 7'd96) reference_note = n - 7'd24;
            else if (n < 7'd108) reference_note = n - 7'd36;
            else reference_note = 7'd60;
            case (reference_note)
                7'd60: base=32'd23012828; 7'd61: base=32'd24381242;
                7'd62: base=32'd25831026; 7'd63: base=32'd27367019;
                7'd64: base=32'd28994347; 7'd65: base=32'd30718440;
                7'd66: base=32'd32545054; 7'd67: base=32'd34480283;
                7'd68: base=32'd36530588; 7'd69: base=32'd38702809;
                7'd70: base=32'd41004198; default: base=32'd43442435;
            endcase
            if (n < 7'd24) note_step = base >> 4;
            else if (n < 7'd36) note_step = base >> 3;
            else if (n < 7'd48) note_step = base >> 2;
            else if (n < 7'd60) note_step = base >> 1;
            else if (n < 7'd72) note_step = base;
            else if (n < 7'd84) note_step = base << 1;
            else if (n < 7'd96) note_step = base << 2;
            else if (n < 7'd108) note_step = base << 3;
            else note_step = base << 4;
        end
    endfunction
    function signed [15:0] triangle;
        input [31:0] phase_value;
        reg [14:0] magnitude;
        begin
            magnitude = phase_value[31] ? ~phase_value[30:16] : phase_value[30:16];
            triangle = $signed({1'b0, magnitude}) - 16'sd16384;
        end
    endfunction

    // Priority selection occurs only on Note On; idle/releasing slots are
    // reused before a physically held note is stolen.
    reg found_match, found_idle, found_released;
    reg [4:0] match_slot, idle_slot, released_slot, chosen_slot;
    always @* begin
        found_match=0; found_idle=0; found_released=0;
        match_slot=0; idle_slot=0; released_slot=0;
        for (s=0; s<32; s=s+1) begin
            if (!found_match && gate_bits[s] && note_mem[s]==data1[6:0]) begin
                found_match=1; match_slot=s[4:0];
            end
            if (!found_idle && !gate_bits[s] && env_mem[s]==0) begin
                found_idle=1; idle_slot=s[4:0];
            end
            if (!found_released && !key_bits[s] && env_mem[s]!=0) begin
                found_released=1; released_slot=s[4:0];
            end
        end
        chosen_slot=found_match ? match_slot : found_idle ? idle_slot :
                    found_released ? released_slot : steal_ptr;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_bits<=0; key_bits<=0; sustain_on<=0; steal_ptr<=0;
            scan_idx<=0; scan_stage<=0; scanning<=0;
            audio_sample<=0; sample_valid<=0; mix_acc<=0;
            active_count<=0; scan_count<=0;
            phase_q<=0; step_q<=0; velocity_q<=0; env_q<=0;
            step_product_q<=0; wave_q<=0; velocity_product_q<=0;
            contribution_q<=0;
            for (j=0;j<32;j=j+1) begin
                note_mem[j]<=0; velocity_mem[j]<=0; step_mem[j]<=0;
                phase_mem[j]<=0; env_mem[j]<=0; release_div[j]<=0;
            end
        end else begin
            sample_valid<=0;
            if (sample_tick) begin
                scanning<=1; scan_idx<=0; scan_stage<=0;
                mix_acc<=0; scan_count<=0;
            end else if (scanning) begin
                case (scan_stage)
                    3'd0: begin
                        phase_q<=phase_mem[scan_idx];
                        step_q<=step_mem[scan_idx];
                        velocity_q<=velocity_mem[scan_idx];
                        env_q<=env_mem[scan_idx];
                        if (env_mem[scan_idx]!=0) scan_count<=scan_count+1'b1;
                        if (gate_bits[scan_idx]) begin
                            release_div[scan_idx]<=0;
                            if (env_mem[scan_idx] < 8'd251)
                                env_mem[scan_idx]<=env_mem[scan_idx]+8'd4;
                            else env_mem[scan_idx]<=8'd255;
                        end else if (env_mem[scan_idx]!=0) begin
                            release_div[scan_idx]<=release_div[scan_idx]+1'b1;
                            if (release_div[scan_idx]==4'd15)
                                env_mem[scan_idx]<=env_mem[scan_idx]-1'b1;
                        end
                        scan_stage<=3'd1;
                    end
                    3'd1: begin
                        step_product_q<=step_q*bend_factor_q14;
                        scan_stage<=3'd2;
                    end
                    3'd2: begin
                        phase_mem[scan_idx]<=phase_q+step_product_q[45:14];
                        wave_q<=triangle(phase_q+step_product_q[45:14]);
                        scan_stage<=3'd3;
                    end
                    3'd3: begin
                        velocity_product_q<=wave_q*$signed({1'b0,velocity_q});
                        scan_stage<=3'd4;
                    end
                    3'd4: begin
                        contribution_q<=velocity_product_q*$signed({1'b0,env_q});
                        scan_stage<=3'd5;
                    end
                    3'd5: begin
                        // /2^20: per-voice peak ~506; 32 voices stay safe.
                        mix_acc<=mix_acc+(contribution_q>>>20);
                        if (scan_idx==5'd31) begin
                            active_count<=scan_count;
                            scan_stage<=3'd6;
                        end else begin
                            scan_idx<=scan_idx+1'b1;
                            scan_stage<=0;
                        end
                    end
                    default: begin
                        // A separate register boundary keeps the 32-slot sum
                        // and output gain out of the same timing path.
                        audio_sample<=mix_acc <<< gain_shift;
                        sample_valid<=1;
                        scanning<=0;
                    end
                endcase
            end
            if (frame_valid) begin
                if (event_type==8'h01 && data2[6:0]!=0) begin
                    note_mem[chosen_slot]<=data1[6:0];
                    velocity_mem[chosen_slot]<=data2[6:0];
                    step_mem[chosen_slot]<=note_step(data1[6:0]);
                    phase_mem[chosen_slot]<=0;
                    env_mem[chosen_slot]<=0;
                    release_div[chosen_slot]<=0;
                    gate_bits[chosen_slot]<=1;
                    key_bits[chosen_slot]<=1;
                    steal_ptr<=chosen_slot+1'b1;
                end else if (event_type==8'h02 ||
                            (event_type==8'h01 && data2[6:0]==0)) begin
                    for (j=0;j<32;j=j+1)
                        if (gate_bits[j] && note_mem[j]==data1[6:0]) begin
                            key_bits[j]<=0;
                            if (!sustain_on) gate_bits[j]<=0;
                        end
                end else if (event_type==8'h03 && data1==8'd64) begin
                    sustain_on<=data2[6:0]>=7'd64;
                    if (data2[6:0]<7'd64) gate_bits<=gate_bits&key_bits;
                end else if (event_type==8'h03 && data1==8'd123) begin
                    gate_bits<=0; key_bits<=0; sustain_on<=0;
                end
            end
        end
    end
endmodule
