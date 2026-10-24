module pt8211_tx (
    input  wire              clk,
    input  wire              rst_n,
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    output reg               bck,
    output reg               ws,
    output reg               din
);
    // 50 MHz / (2 * 16) = 1.5625 MHz BCK.
    // 32 BCK per stereo frame gives 48.828125 kHz sample rate.
    reg [3:0] divider;
    reg [4:0] bit_index;
    reg [15:0] left_latched;
    reg [15:0] right_latched;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider       <= 4'd0;
            bit_index     <= 5'd0;
            left_latched  <= 16'd0;
            right_latched <= 16'd0;
            bck           <= 1'b0;
            ws            <= 1'b0;
            din           <= 1'b0;
        end else if (divider == 4'd15) begin
            divider <= 4'd0;
            if (!bck) begin
                // PT8211 samples DIN on BCK rising edges.
                bck <= 1'b1;
            end else begin
                // Change DIN and WS on falling edges, safely before next rising edge.
                bck <= 1'b0;
                if (bit_index == 5'd31) begin
                    bit_index     <= 5'd0;
                    left_latched  <= sample_left;
                    right_latched <= sample_right;
                    ws            <= 1'b0;
                    din           <= sample_right[15];
                end else begin
                    bit_index <= bit_index + 1'b1;
                    if (bit_index == 5'd15) begin
                        ws  <= 1'b1;
                        din <= left_latched[15];
                    end else if (bit_index < 5'd15) begin
                        ws  <= 1'b0;
                        din <= right_latched[14-bit_index];
                    end else begin
                        ws  <= 1'b1;
                        din <= left_latched[30-bit_index];
                    end
                end
            end
        end else begin
            divider <= divider + 1'b1;
        end
    end
endmodule
