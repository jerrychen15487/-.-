module uart_rx #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer BAUD     = 1_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        framing_error
);
    localparam integer CLKS_PER_BIT = CLOCK_HZ / BAUD;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;

    reg rx_meta, rx_sync, rx_prev;
    reg [7:0] shift;
    // Wide enough for lower diagnostic baud rates as well as the 1 Mbps
    // production link.  At 50 MHz, 115200 baud needs 434 clocks per bit.
    reg [15:0] clk_count;
    reg [3:0] bit_index;
    reg busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data          <= 8'h00;
            valid         <= 1'b0;
            framing_error <= 1'b0;
            shift         <= 8'h00;
            clk_count     <= 16'd0;
            bit_index     <= 4'd0;
            busy          <= 1'b0;
        end else begin
            valid         <= 1'b0;
            framing_error <= 1'b0;

            if (!busy) begin
                if (rx_prev && !rx_sync) begin
                    busy      <= 1'b1;
                    clk_count <= HALF_BIT - 1;
                    bit_index <= 4'd0;
                end
            end else if (clk_count != 0) begin
                clk_count <= clk_count - 1'b1;
            end else if (bit_index == 0) begin
                if (!rx_sync) begin
                    bit_index <= 4'd1;
                    clk_count <= CLKS_PER_BIT - 1;
                end else begin
                    busy <= 1'b0;
                end
            end else if (bit_index <= 8) begin
                shift[bit_index-1] <= rx_sync;
                bit_index <= bit_index + 1'b1;
                clk_count <= CLKS_PER_BIT - 1;
            end else begin
                busy <= 1'b0;
                if (rx_sync) begin
                    data  <= shift;
                    valid <= 1'b1;
                end else begin
                    framing_error <= 1'b1;
                end
            end
        end
    end
endmodule
