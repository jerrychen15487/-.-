// 8N1 transmitter, one byte at a time. clk must divide BAUD exactly.
module score_uart_tx #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD = 1_000_000
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [7:0] data,
    output wire ready,
    output wire tx
);
    localparam integer CLKS_PER_BIT = CLOCK_HZ / BAUD;
    reg [9:0] shift;
    reg [15:0] ticks;
    reg [3:0] bit_no;
    reg busy;
    assign ready = !busy;
    assign tx = busy ? shift[0] : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift <= 10'h3ff;
            ticks <= 0;
            bit_no <= 0;
            busy <= 0;
        end else if (!busy) begin
            if (start) begin
                shift <= {1'b1, data, 1'b0};
                ticks <= CLKS_PER_BIT - 1;
                bit_no <= 0;
                busy <= 1;
            end
        end else if (ticks != 0) begin
            ticks <= ticks - 1'b1;
        end else if (bit_no == 4'd9) begin
            busy <= 0;
        end else begin
            shift <= {1'b1, shift[9:1]};
            ticks <= CLKS_PER_BIT - 1;
            bit_no <= bit_no + 1'b1;
        end
    end
endmodule
