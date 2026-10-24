// F3 transport probe only. It validates complete UART v2 frames and replies
// with an explicit error; it NEVER advertises a downloadable song library.
// No PSC2 data is accepted or acknowledged as persistent.
module score_uart_v2_probe (
    input wire clk,
    input wire rst_n,
    input wire rx,
    output wire tx,
    output reg valid_request_pulse,
    output reg crc_error_pulse
);
    wire [7:0] rx_byte;
    wire rx_valid, framing_error;
    uart_rx #(.CLOCK_HZ(50_000_000), .BAUD(1_000_000)) receiver (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(rx_byte),
        .valid(rx_valid), .framing_error(framing_error)
    );

    reg tx_start;
    reg [7:0] tx_byte;
    wire tx_ready;
    score_uart_tx #(.CLOCK_HZ(50_000_000), .BAUD(1_000_000)) sender (
        .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_byte),
        .ready(tx_ready), .tx(tx)
    );

    // CRC-32/ISO-HDLC, reflected. One byte is consumed in 8 combinational
    // rounds; at 1 Mbps there are 500 system clocks between received bytes.
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer i;
        begin
            c = previous ^ {24'd0, octet};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ((c >> 1) ^ 32'hedb88320) : (c >> 1);
            crc_byte = c;
        end
    endfunction

    localparam RECEIVE = 2'd0, PREPARE = 2'd1, REPLY = 2'd2;
    reg [1:0] state;
    reg [10:0] pos;
    reg [15:0] payload_len;
    reg [7:0] request_type;
    reg [31:0] session, seq;
    reg [31:0] received_crc, running_crc, reply_crc;
    reg [22:0] gap_ticks;
    reg [4:0] reply_pos;
    reg [15:0] error_code;

    function [7:0] reply_data;
        input [4:0] index;
        begin
            case (index)
                0: reply_data = 8'ha5;
                1: reply_data = 8'h5a;
                2: reply_data = 8'h02;
                3: reply_data = 8'hff;
                4: reply_data = session[7:0];
                5: reply_data = session[15:8];
                6: reply_data = session[23:16];
                7: reply_data = session[31:24];
                8: reply_data = seq[7:0];
                9: reply_data = seq[15:8];
                10: reply_data = seq[23:16];
                11: reply_data = seq[31:24];
                12: reply_data = 8'd8;  // ERROR payload length
                13, 14, 15: reply_data = 8'd0;
                16: reply_data = request_type;
                17: reply_data = 8'd0;
                18: reply_data = error_code[7:0];
                19: reply_data = error_code[15:8];
                20, 21, 22, 23: reply_data = 8'hff; // no next block
                24: reply_data = ~reply_crc[7:0];
                25: reply_data = ~reply_crc[15:8];
                26: reply_data = ~reply_crc[23:16];
                27: reply_data = ~reply_crc[31:24];
                default: reply_data = 8'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= RECEIVE;
            pos <= 0;
            payload_len <= 0;
            request_type <= 0;
            session <= 0;
            seq <= 0;
            received_crc <= 0;
            running_crc <= 32'hffffffff;
            reply_crc <= 32'hffffffff;
            gap_ticks <= 0;
            reply_pos <= 0;
            error_code <= 16'h0008;
            tx_start <= 0;
            tx_byte <= 0;
            valid_request_pulse <= 0;
            crc_error_pulse <= 0;
        end else begin
            tx_start <= 0;
            valid_request_pulse <= 0;
            crc_error_pulse <= 0;
            case (state)
                RECEIVE: begin
                    if (framing_error) begin
                        pos <= 0;
                        gap_ticks <= 0;
                    end else if (rx_valid) begin
                        gap_ticks <= 0;
                        if (pos == 0) begin
                            if (rx_byte == 8'ha5) pos <= 1;
                        end else if (pos == 1) begin
                            if (rx_byte == 8'h5a) begin
                                pos <= 2;
                                running_crc <= 32'hffffffff;
                                received_crc <= 0;
                                payload_len <= 0;
                                session <= 0;
                                seq <= 0;
                            end else begin
                                pos <= (rx_byte == 8'ha5) ? 1 : 0;
                            end
                        end else if (pos == 2 && rx_byte != 8'h02) begin
                            pos <= (rx_byte == 8'ha5) ? 1 : 0;
                        end else if (pos == 15 &&
                                     (rx_byte != 0 || payload_len > 16'd1024)) begin
                            pos <= (rx_byte == 8'ha5) ? 1 : 0;
                        end else if (pos == 14 && rx_byte != 0) begin
                            pos <= (rx_byte == 8'ha5) ? 1 : 0;
                        end else begin
                            if (pos < (16 + payload_len))
                                running_crc <= crc_byte(running_crc, rx_byte);
                            case (pos)
                                3: request_type <= rx_byte;
                                4: session[7:0] <= rx_byte;
                                5: session[15:8] <= rx_byte;
                                6: session[23:16] <= rx_byte;
                                7: session[31:24] <= rx_byte;
                                8: seq[7:0] <= rx_byte;
                                9: seq[15:8] <= rx_byte;
                                10: seq[23:16] <= rx_byte;
                                11: seq[31:24] <= rx_byte;
                                12: payload_len[7:0] <= rx_byte;
                                13: payload_len[15:8] <= rx_byte;
                                default: begin end
                            endcase
                            if (pos >= (16 + payload_len) &&
                                pos < (19 + payload_len))
                                received_crc <= {rx_byte, received_crc[31:8]};
                            if (pos == (19 + payload_len)) begin
                                pos <= 0;
                                if ({rx_byte, received_crc[31:8]} == ~running_crc) begin
                                    if (session != 0 && seq != 0 &&
                                        request_type != 8'h80 && request_type != 8'h90 &&
                                        request_type != 8'hff) begin
                                        valid_request_pulse <= 1;
                                        error_code <= ((request_type == 8'h01) ||
                                                       (request_type == 8'h02) ||
                                                       (request_type == 8'h03) ||
                                                       (request_type >= 8'h10 &&
                                                        request_type <= 8'h14)) ?
                                                      16'h0008 : 16'h000d;
                                        reply_crc <= 32'hffffffff;
                                        reply_pos <= 2;
                                        state <= PREPARE;
                                    end
                                end else crc_error_pulse <= 1;
                            end else pos <= pos + 1'b1;
                        end
                    end else if (pos != 0) begin
                        if (gap_ticks == 23'd4999999) begin
                            pos <= 0; // >100 ms between bytes: abandon frame
                            gap_ticks <= 0;
                        end else gap_ticks <= gap_ticks + 1'b1;
                    end
                end
                PREPARE: begin
                    if (reply_pos < 24) begin
                        reply_crc <= crc_byte(reply_crc, reply_data(reply_pos));
                        reply_pos <= reply_pos + 1'b1;
                    end else begin
                        reply_pos <= 0;
                        state <= REPLY;
                    end
                end
                REPLY: begin
                    if (tx_ready && !tx_start) begin
                        if (reply_pos < 28) begin
                            tx_byte <= reply_data(reply_pos);
                            tx_start <= 1;
                            reply_pos <= reply_pos + 1'b1;
                        end else state <= RECEIVE;
                    end
                end
                default: state <= RECEIVE;
            endcase
        end
    end
endmodule
