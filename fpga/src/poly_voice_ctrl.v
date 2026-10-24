module poly_voice_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_valid,
    input  wire [7:0] event_type,
    input  wire [7:0] data1,
    input  wire [7:0] data2,
    input  wire [3:0] voice_finished,

    output reg  [6:0] note0,
    output reg  [6:0] note1,
    output reg  [6:0] note2,
    output reg  [6:0] note3,
    output reg  [6:0] velocity0,
    output reg  [6:0] velocity1,
    output reg  [6:0] velocity2,
    output reg  [6:0] velocity3,
    output reg  [3:0] gate,
    output reg  [3:0] retrigger
);
    // Reuse an idle voice first, then a pedal-held released key, then steal
    // a physically held voice in round-robin order.
    reg [1:0] steal_ptr;
    // gate drives the audio envelope; key_down records the physical key.
    // Under CC64 a released key keeps its gate until the pedal is lifted.
    reg [3:0] key_down;
    reg sustain_on;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note0      <= 7'd60;
            note1      <= 7'd64;
            note2      <= 7'd67;
            note3      <= 7'd72;
            velocity0  <= 7'd0;
            velocity1  <= 7'd0;
            velocity2  <= 7'd0;
            velocity3  <= 7'd0;
            gate        <= 4'b0000;
            retrigger   <= 4'b0000;
            steal_ptr   <= 2'd0;
            key_down    <= 4'b0000;
            sustain_on  <= 1'b0;
        end else begin
            retrigger <= 4'b0000;
            if (voice_finished[0]) begin gate[0] <= 1'b0; key_down[0] <= 1'b0; end
            if (voice_finished[1]) begin gate[1] <= 1'b0; key_down[1] <= 1'b0; end
            if (voice_finished[2]) begin gate[2] <= 1'b0; key_down[2] <= 1'b0; end
            if (voice_finished[3]) begin gate[3] <= 1'b0; key_down[3] <= 1'b0; end

            if (frame_valid) begin
                if ((event_type == 8'h01) && (data2[6:0] != 0)) begin
                    // Repeated Note On reuses the voice already assigned to
                    // that pitch, which avoids duplicate stuck notes.
                    if (gate[0] && (note0 == data1[6:0])) begin
                        velocity0 <= data2[6:0];
                        gate[0] <= 1'b1;
                        key_down[0] <= 1'b1;
                        retrigger[0] <= 1'b1;
                    end else if (gate[1] && (note1 == data1[6:0])) begin
                        velocity1 <= data2[6:0];
                        gate[1] <= 1'b1;
                        key_down[1] <= 1'b1;
                        retrigger[1] <= 1'b1;
                    end else if (gate[2] && (note2 == data1[6:0])) begin
                        velocity2 <= data2[6:0];
                        gate[2] <= 1'b1;
                        key_down[2] <= 1'b1;
                        retrigger[2] <= 1'b1;
                    end else if (gate[3] && (note3 == data1[6:0])) begin
                        velocity3 <= data2[6:0];
                        gate[3] <= 1'b1;
                        key_down[3] <= 1'b1;
                        retrigger[3] <= 1'b1;
                    end else if (!gate[0]) begin
                        note0 <= data1[6:0]; velocity0 <= data2[6:0];
                        gate[0] <= 1'b1; retrigger[0] <= 1'b1;
                        key_down[0] <= 1'b1;
                        steal_ptr <= 2'd1;
                    end else if (!gate[1]) begin
                        note1 <= data1[6:0]; velocity1 <= data2[6:0];
                        gate[1] <= 1'b1; retrigger[1] <= 1'b1;
                        key_down[1] <= 1'b1;
                        steal_ptr <= 2'd2;
                    end else if (!gate[2]) begin
                        note2 <= data1[6:0]; velocity2 <= data2[6:0];
                        gate[2] <= 1'b1; retrigger[2] <= 1'b1;
                        key_down[2] <= 1'b1;
                        steal_ptr <= 2'd3;
                    end else if (!gate[3]) begin
                        note3 <= data1[6:0]; velocity3 <= data2[6:0];
                        gate[3] <= 1'b1; retrigger[3] <= 1'b1;
                        key_down[3] <= 1'b1;
                        steal_ptr <= 2'd0;
                    end else if (!key_down[0]) begin
                        note0 <= data1[6:0]; velocity0 <= data2[6:0];
                        gate[0] <= 1'b1; retrigger[0] <= 1'b1; key_down[0] <= 1'b1;
                        steal_ptr <= 2'd1;
                    end else if (!key_down[1]) begin
                        note1 <= data1[6:0]; velocity1 <= data2[6:0];
                        gate[1] <= 1'b1; retrigger[1] <= 1'b1; key_down[1] <= 1'b1;
                        steal_ptr <= 2'd2;
                    end else if (!key_down[2]) begin
                        note2 <= data1[6:0]; velocity2 <= data2[6:0];
                        gate[2] <= 1'b1; retrigger[2] <= 1'b1; key_down[2] <= 1'b1;
                        steal_ptr <= 2'd3;
                    end else if (!key_down[3]) begin
                        note3 <= data1[6:0]; velocity3 <= data2[6:0];
                        gate[3] <= 1'b1; retrigger[3] <= 1'b1; key_down[3] <= 1'b1;
                        steal_ptr <= 2'd0;
                    end else begin
                        case (steal_ptr)
                            2'd0: begin note0 <= data1[6:0]; velocity0 <= data2[6:0]; retrigger[0] <= 1'b1; key_down[0] <= 1'b1; end
                            2'd1: begin note1 <= data1[6:0]; velocity1 <= data2[6:0]; retrigger[1] <= 1'b1; key_down[1] <= 1'b1; end
                            2'd2: begin note2 <= data1[6:0]; velocity2 <= data2[6:0]; retrigger[2] <= 1'b1; key_down[2] <= 1'b1; end
                            2'd3: begin note3 <= data1[6:0]; velocity3 <= data2[6:0]; retrigger[3] <= 1'b1; key_down[3] <= 1'b1; end
                        endcase
                        gate[steal_ptr] <= 1'b1;
                        steal_ptr <= steal_ptr + 1'b1;
                    end
                end else if ((event_type == 8'h02) ||
                             ((event_type == 8'h01) && (data2[6:0] == 0))) begin
                    // Release every matching held voice. Normally there is
                    // only one, but clearing all matches is safer after a
                    // retransmitted MIDI packet.
                    if (gate[0] && (note0 == data1[6:0])) begin key_down[0] <= 1'b0; if (!sustain_on) gate[0] <= 1'b0; end
                    if (gate[1] && (note1 == data1[6:0])) begin key_down[1] <= 1'b0; if (!sustain_on) gate[1] <= 1'b0; end
                    if (gate[2] && (note2 == data1[6:0])) begin key_down[2] <= 1'b0; if (!sustain_on) gate[2] <= 1'b0; end
                    if (gate[3] && (note3 == data1[6:0])) begin key_down[3] <= 1'b0; if (!sustain_on) gate[3] <= 1'b0; end
                end else if ((event_type == 8'h03) && (data1 == 8'd64)) begin
                    sustain_on <= (data2[6:0] >= 7'd64);
                    if (data2[6:0] < 7'd64)
                        gate <= gate & key_down;
                end else if ((event_type == 8'h03) && (data1 == 8'd123)) begin
                    gate <= 4'b0000;
                    key_down <= 4'b0000;
                end
            end
        end
    end
endmodule
