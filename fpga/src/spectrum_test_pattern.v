// Bench-only note source for the official multi-frequency spectrum demo.
// Four ordinary Note On events enter the same voice allocator and DDS path as
// USB-MIDI. Re-trigger before the organ envelope's natural fade so the four
// fundamentals remain visible during a long demonstration.
module spectrum_test_pattern #(
    parameter integer REPEAT_SAMPLES = 24576
) (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    output wire frame_valid,
    output wire [7:0] event_type,
    output wire [7:0] data1,
    output wire [7:0] data2
);
    reg [14:0] sample_index;
    assign frame_valid = sample_tick && sample_index < 15'd4;
    assign event_type = 8'h01;
    assign data2 = 8'd100;
    // G3/D4/A4/E5: approximately 196/294/440/659 Hz. The display FFT
    // averages 16 audio samples, yielding 47.68 Hz per bin; these four
    // fundamentals fall in non-adjacent bins 4, 6, 9 and 14.
    assign data1 = sample_index == 15'd0 ? 8'd55 :
                   sample_index == 15'd1 ? 8'd62 :
                   sample_index == 15'd2 ? 8'd69 : 8'd76;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample_index <= 15'd0;
        else if (sample_tick) begin
            if (sample_index == REPEAT_SAMPLES-1)
                sample_index <= 15'd0;
            else
                sample_index <= sample_index + 1'b1;
        end
    end
endmodule
