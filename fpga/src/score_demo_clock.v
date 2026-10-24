// Lightweight PSC2 preview clock. Beginner preview plays at half the score
// BPM and starts each loop with enough lead-in for the first note to travel
// from the top of the piano roll to the keyboard line.
module score_demo_clock #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer TICKS_PER_BPM = 8,
    parameter [31:0] LEAD_IN_TICKS = 32'd7168,
    parameter integer STOP_AT_END = 0
) (
    input  wire        pixel_clk,
    input  wire        rst_n,
    input  wire        active,
    input  wire        paused,
    input  wire [15:0] bpm,
    input  wire [31:0] loop_ticks,
    output reg  [31:0] current_tick,
    output reg  [11:0] current_scroll_px
);
    localparam [25:0] CLOCK_RATE = CLOCK_HZ;
    wire [15:0] effective_bpm =
        (bpm>=16'd20 && bpm<=16'd300) ? bpm : 16'd112;
    wire [25:0] tick_rate = effective_bpm*TICKS_PER_BPM;
    wire [25:0] threshold = CLOCK_RATE - tick_rate;
    // One BPM worth of ticks is 125 ms at the half-speed preview rate.
    // Leave this tail after the last note ends so the +100 ms hit window
    // and the one-tick-later Miss sweep complete before a loop restart.
    wire [31:0] loop_source =
        loop_ticks>=32'd960 ? loop_ticks : 32'd3840;
    reg [31:0] loop_base_q, loop_terminal_q;
    reg [25:0] phase;
    reg [15:0] scroll_fraction;
    wire [16:0] scroll_sum={1'b0,scroll_fraction}+17'd3291;

    // Cache the loop bound in two stages. BPM -> 32-bit addition -> loop
    // comparison -> scroll reset was a measured 50 MHz critical path.
    // The preview cache is stable before active rises, and BPM changes only
    // before playback or while paused, leaving both stages time to settle.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_base_q <= 32'd3840 + LEAD_IN_TICKS + 32'd1;
            loop_terminal_q <= 32'd3840 + LEAD_IN_TICKS + 32'd113;
        end else begin
            loop_base_q <= loop_source + LEAD_IN_TICKS + 32'd1;
            loop_terminal_q <= loop_base_q + {16'd0,effective_bpm};
        end
    end

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 26'd0;
            current_tick <= 32'd0;
            scroll_fraction <= 16'd0;
            current_scroll_px <= 12'd0;
        end else if (!active) begin
            phase <= 26'd0;
            current_tick <= 32'd0;
            scroll_fraction <= 16'd0;
            current_scroll_px <= 12'd0;
        end else if (paused) begin
            // Hold the fractional phase too, so resume continues seamlessly.
        end else if (phase >= threshold) begin
            phase <= phase + tick_rate - CLOCK_RATE;
            if (current_tick >= loop_terminal_q) begin
                if (!STOP_AT_END) begin
                    current_tick <= 32'd0;
                    scroll_fraction <= 16'd0;
                    current_scroll_px <= 12'd0;
                end
            end else begin
                current_tick <= current_tick + 1'b1;
                scroll_fraction <= scroll_sum[15:0];
                if(scroll_sum[16] && current_scroll_px!=12'hfff)
                    current_scroll_px <= current_scroll_px + 1'b1;
            end
        end else begin
            phase <= phase + tick_rate;
        end
    end
endmodule
