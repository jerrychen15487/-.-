// ESP32-S3 SPI2 -> FPGA: mode 0, MSB first, exactly six bytes per CS.
// SCLK, MOSI and CS are asynchronous to the 50 MHz FPGA clock. The inputs
// are synchronized before SCLK rising edges are detected in this clock domain.
// A frame is published only after CS rises and exactly 48 bits were received.
module spi_midi_frame_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       spi_sclk_i,
    input  wire       spi_mosi_i,
    input  wire       spi_cs_n_i,
    output wire       spi_ready_o,
    output reg        frame_valid,
    output reg  [7:0] event_type,
    output reg  [7:0] route,
    output reg  [7:0] midi_parameter,
    output reg  [7:0] value
);
    (* ASYNC_REG = "TRUE" *) reg [2:0] cs_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] sclk_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] mosi_sync;
    reg cs_previous;
    reg sclk_previous;
    reg [5:0] bit_count;
    reg [47:0] bits;

    // READY is high only while idle. It is not an ACK for a completed frame.
    // Once CS falls, the complete transaction is accepted even though READY
    // goes low. The ESP32 must not start another frame until READY returns high.
    assign spi_ready_o = rst_n && cs_sync[2] && (bit_count == 6'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_sync      <= 3'b111;
            sclk_sync    <= 3'b000;
            mosi_sync    <= 3'b000;
            cs_previous  <= 1'b1;
            sclk_previous <= 1'b0;
            bit_count    <= 6'd0;
            bits         <= 48'd0;
            frame_valid  <= 1'b0;
            event_type   <= 8'd0;
            route        <= 8'd0;
            midi_parameter <= 8'd0;
            value        <= 8'd0;
        end else begin
            cs_sync   <= {cs_sync[1:0], spi_cs_n_i};
            sclk_sync <= {sclk_sync[1:0], spi_sclk_i};
            mosi_sync <= {mosi_sync[1:0], spi_mosi_i};
            cs_previous   <= cs_sync[2];
            sclk_previous <= sclk_sync[2];
            frame_valid <= 1'b0;

            if (cs_sync[2]) begin
                // The sampled CS rising edge closes one transaction. Reject
                // short/long frames and reserved/invalid MIDI fields.
                if (!cs_previous && (bit_count == 6'd48) &&
                    ((bits[47:40] == 8'h01) ||
                     (bits[47:40] == 8'h02) ||
                     (bits[47:40] == 8'h03) ||
                     (bits[47:40] == 8'h04) ||
                     (bits[47:40] == 8'h05)) &&
                    !bits[31] && !bits[23] &&
                    (bits[15:0] == 16'h0000)) begin
                    event_type  <= bits[47:40];
                    route       <= bits[39:32];
                    midi_parameter <= bits[31:24];
                    value       <= bits[23:16];
                    frame_valid <= 1'b1;
                end
                bit_count <= 6'd0;
            end else if (!sclk_previous && sclk_sync[2]) begin
                // Saturate at 49 so an overlong frame cannot wrap to 48.
                if (bit_count < 6'd49) begin
                    bit_count <= bit_count + 1'b1;
                    bits <= {bits[46:0], mosi_sync[2]};
                end
            end
        end
    end
endmodule
