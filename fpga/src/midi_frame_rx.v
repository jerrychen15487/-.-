module midi_frame_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] rx_data,
    input  wire       rx_valid,
    output reg        frame_valid,
    output reg        crc_error,
    output reg  [7:0] sequence,
    output reg  [7:0] event_type,
    output reg  [7:0] channel,
    output reg  [7:0] data1,
    output reg  [7:0] data2
);
    reg [3:0] index;
    reg [7:0] crc;
    reg [7:0] frame [0:6];
    integer i;

    function [7:0] crc8_atm;
        input [7:0] crc_in;
        input [7:0] byte_in;
        integer k;
        reg [7:0] c;
        begin
            c = crc_in ^ byte_in;
            for (k = 0; k < 8; k = k + 1)
                c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8_atm = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            index       <= 4'd0;
            crc         <= 8'h00;
            frame_valid <= 1'b0;
            crc_error   <= 1'b0;
            sequence    <= 8'h00;
            event_type  <= 8'h00;
            channel     <= 8'h00;
            data1       <= 8'h00;
            data2       <= 8'h00;
            for (i = 0; i < 7; i = i + 1)
                frame[i] <= 8'h00;
        end else begin
            frame_valid <= 1'b0;
            crc_error   <= 1'b0;
            if (rx_valid) begin
                case (index)
                    0: begin
                        if (rx_data == 8'hA5) begin
                            frame[0] <= rx_data;
                            crc      <= crc8_atm(8'h00, rx_data);
                            index    <= 4'd1;
                        end
                    end
                    1: begin
                        if (rx_data == 8'h5A) begin
                            frame[1] <= rx_data;
                            crc      <= crc8_atm(crc, rx_data);
                            index    <= 4'd2;
                        end else if (rx_data == 8'hA5) begin
                            frame[0] <= rx_data;
                            crc      <= crc8_atm(8'h00, rx_data);
                            index    <= 4'd1;
                        end else begin
                            index <= 4'd0;
                        end
                    end
                    2,3,4,5,6: begin
                        frame[index] <= rx_data;
                        crc          <= crc8_atm(crc, rx_data);
                        index        <= index + 1'b1;
                    end
                    7: begin
                        index <= 4'd0;
                        if (rx_data == crc) begin
                            sequence    <= frame[2];
                            event_type  <= frame[3];
                            channel     <= frame[4];
                            data1       <= frame[5];
                            data2       <= frame[6];
                            frame_valid <= 1'b1;
                        end else begin
                            crc_error <= 1'b1;
                        end
                    end
                    default: index <= 4'd0;
                endcase
            end
        end
    end
endmodule
