// Standard I2S, 16-bit two's-complement samples in 32-bit stereo slots.
// At 50 MHz: BCK = 50 MHz / 16 = 3.125 MHz and LRCK = BCK / 64
// = 48.828125 kHz, matching the existing 1024-clock audio sample period.
// WS changes one BCK before the next channel's MSB; DIN changes only on
// BCK falling edges and is sampled by the DAC on rising edges.
module pcm5102_i2s_tx (
    input  wire              clk,
    input  wire              rst_n,
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    output reg               bck,
    output reg               ws,
    output reg               din
);
    reg [2:0] divider;
    reg [5:0] slot;
    reg [15:0] left_shift;
    reg [15:0] right_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider     <= 3'd0;
            slot        <= 6'd63;
            left_shift  <= 16'd0;
            right_shift <= 16'd0;
            bck         <= 1'b0;
            ws          <= 1'b1;
            din         <= 1'b0;
        end else if (divider == 3'd7) begin
            divider <= 3'd0;
            if (!bck) begin
                bck <= 1'b1;
            end else begin
                bck <= 1'b0;
                slot <= slot + 1'b1;
                if (slot == 6'd63) begin
                    // Start left slot. The first BCK after the WS edge is
                    // the I2S one-bit delay; sample both channels together.
                    ws          <= 1'b0;
                    din         <= 1'b0;
                    left_shift  <= sample_left;
                    right_shift <= sample_right;
                end else if (slot == 6'd31) begin
                    // Start right slot with the same one-bit delay.
                    ws  <= 1'b1;
                    din <= 1'b0;
                end else if (slot < 6'd16) begin
                    // Slots 1..16 carry left sample MSB first.
                    din        <= left_shift[15];
                    left_shift <= {left_shift[14:0], 1'b0};
                end else if (slot >= 6'd32 && slot < 6'd48) begin
                    // Slots 33..48 carry right sample MSB first.
                    din         <= right_shift[15];
                    right_shift <= {right_shift[14:0], 1'b0};
                end else begin
                    din <= 1'b0;
                end
            end
        end else begin
            divider <= divider + 1'b1;
        end
    end
endmodule
