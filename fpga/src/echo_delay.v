// One FPGA-local slapback echo. The single 8192x16 delay line is synchronous
// RAM (no array reset or asynchronous read), suitable for BSRAM inference.
// No feedback: each note gets one quiet repeat rather than an unstable loop.
module echo_delay #(
    parameter integer DELAY_BITS = 13
) (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire enable,
    input wire signed [15:0] dry_in,
    output reg signed [15:0] audio_out
);
    reg signed [15:0] delay_mem [0:(1<<DELAY_BITS)-1];
    reg [DELAY_BITS-1:0] write_ptr;
    reg delay_valid;
    reg signed [15:0] delayed_q;
    reg signed [15:0] dry_q;
    reg signed [15:0] wet_q;
    wire signed [16:0] mixed =
        $signed({dry_q[15],dry_q}) + $signed({wet_q[15],wet_q});
    wire signed [15:0] saturated =
        (mixed > 17'sd32767) ? 16'sh7fff :
        (mixed < -17'sd32768) ? 16'sh8000 : mixed[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr <= 0;
            delay_valid <= 1'b0;
            delayed_q <= 16'sd0;
            dry_q <= 16'sd0;
            wet_q <= 16'sd0;
            audio_out <= 16'sd0;
        end else if (sample_tick) begin
            // Read-before-write at the same address; the delayed sample is
            // captured before this sample replaces it. The read register and
            // following wet register also keep the DAC sum off the DDS path.
            delayed_q <= delay_mem[write_ptr];
            delay_mem[write_ptr] <= dry_in;
            write_ptr <= write_ptr + 1'b1;
            if (&write_ptr)
                delay_valid <= 1'b1;
            dry_q <= dry_in;
            wet_q <= delay_valid ? (delayed_q >>> 1) : 16'sd0;
            audio_out <= enable ? saturated : dry_q;
        end
    end
endmodule
