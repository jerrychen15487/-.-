// F5 playback clock: 960 ticks per quarter note, with an integer countdown.
// The fractional phase accumulator keeps the average tempo accurate without
// a run-time divider. Pause freezes both countdown and playback phase.
module f5_score_clock #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer COUNT_IN_SECONDS = 3
) (
    input wire clk, rst_n,
    input wire start, pause,
    input wire [15:0] bpm,
    input wire [31:0] duration_ticks,
    output reg [1:0] state,
    output reg [2:0] countdown,
    output reg [31:0] current_tick,
    output reg tick_ce,
    output wire running,
    output wire complete
);
    localparam [1:0] IDLE=2'd0, COUNT_IN=2'd1, PLAY=2'd2, DONE=2'd3;
    localparam [31:0] COUNT_CYCLES=CLOCK_HZ;
    localparam [31:0] PHASE_LIMIT=CLOCK_HZ*60;
    reg [31:0] count_phase;
    reg [31:0] tick_phase;
    reg [15:0] bpm_q;
    wire [31:0] tick_rate={16'd0,bpm_q}*32'd16;
    wire [32:0] phase_sum={1'b0,tick_phase}+{1'b0,tick_rate};
    assign running=(state==PLAY) && !pause;
    assign complete=(state==DONE);

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;
            countdown<=0;
            current_tick<=0;
            tick_ce<=0;
            count_phase<=0;
            tick_phase<=0;
            bpm_q<=16'd112;
        end else begin
            tick_ce<=0;
            if(start && (state==IDLE || state==DONE)) begin
                state<=COUNT_IN;
                countdown<=COUNT_IN_SECONDS[2:0];
                current_tick<=0;
                count_phase<=0;
                tick_phase<=0;
                bpm_q<=(bpm>=20 && bpm<=300) ? bpm : 16'd112;
            end else if(!pause) begin
                if(state==COUNT_IN) begin
                    if(count_phase==COUNT_CYCLES-1) begin
                        count_phase<=0;
                        if(countdown<=1) begin
                            countdown<=0;
                            state<=PLAY;
                        end else countdown<=countdown-1'b1;
                    end else count_phase<=count_phase+1'b1;
                end else if(state==PLAY) begin
                    if(phase_sum>=PHASE_LIMIT) begin
                        tick_phase<=phase_sum-PHASE_LIMIT;
                        current_tick<=current_tick+1'b1;
                        tick_ce<=1;
                        if(duration_ticks!=0 && current_tick+1'b1>=duration_ticks)
                            state<=DONE;
                    end else tick_phase<=phase_sum[31:0];
                end
            end
        end
    end
endmodule
