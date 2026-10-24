// Dedicated-card SPI block device. One 512-byte buffer and one request at a
// time; requests are accepted only after initialization and external LBA guard.
// A write is followed by a full CMD17 readback before done=1. No automatic
// writes are possible. The live top instantiates this device via score_store_sd.
module sd_spi_block_device (
    input wire clk, input wire rst_n, input wire miso,
    output reg cs_n, output reg sck, output reg mosi,
    input wire req_start, input wire req_write, input wire req_guard_valid,
    input wire [31:0] req_lba,
    output wire ready, output reg init_done, output reg done,
    output reg [7:0] error_code, output reg [31:0] sector_count,
    input wire [8:0] buffer_addr, input wire [7:0] buffer_wdata,
    input wire buffer_we, output wire [7:0] buffer_rdata
);
    localparam S_DUMMY_START=0, S_DUMMY_WAIT=1, S_CMD_START=2,
        S_CMD_WAIT=3, S_RESP_START=4, S_RESP_WAIT=5,
        S_EXTRA_START=6, S_EXTRA_WAIT=7, S_TOKEN_START=8,
        S_TOKEN_WAIT=9, S_DATA_START=10, S_DATA_WAIT=11,
        S_IDLE=12, S_W_GAP_START=13, S_W_GAP_WAIT=14,
        S_W_TOKEN_START=15, S_W_TOKEN_WAIT=16, S_W_DATA_START=17,
        S_W_DATA_WAIT=18, S_W_CRC_START=19, S_W_CRC_WAIT=20,
        S_W_RESP_START=21, S_W_RESP_WAIT=22, S_W_BUSY_START=23,
        S_W_BUSY_WAIT=24, S_FAULT=25;
    reg [4:0] state;
    assign ready = init_done && (state == S_IDLE);

    reg [7:0] block_mem [0:511];
    reg [7:0] command;
    reg [31:0] command_lba;
    reg readback;
    reg [2:0] send_index, extra_index;
    reg [31:0] extra_value, ocr;
    reg [4:0] poll_count;
    reg [15:0] token_count, acmd_retries;
    reg [19:0] busy_count;
    reg [3:0] dummy_count;
    reg [9:0] data_count;
    reg [21:0] csd_c_size;
    reg [1:0] csd_structure;
    reg [15:0] crc_calc;
    reg [7:0] crc_hi;
    reg data_mismatch, crc_low_byte;
    reg [7:0] tx_byte;
    reg byte_start, byte_busy, byte_done;
    reg [7:0] rx_byte, shift_in, shift_out, divider;
    reg [3:0] bit_count;
    assign buffer_rdata = block_mem[buffer_addr];
    always @(posedge clk)
        if (buffer_we && ready && !req_start)
            block_mem[buffer_addr] <= buffer_wdata;
        else if (state == S_DATA_WAIT && byte_done && command == 8'd17 &&
                 !readback && data_count < 10'd512)
            block_mem[data_count[8:0]] <= rx_byte;

    function [7:0] command_byte;
        input [7:0] cmd;
        input [2:0] index;
        input [31:0] lba;
        reg [31:0] argument;
        begin
            argument = (cmd == 8'd17 || cmd == 8'd24) ? lba :
                       (cmd == 8'd41) ? 32'h40000000 :
                       (cmd == 8'd8) ? 32'h000001AA : 32'd0;
            case (index)
                0: command_byte = 8'h40 | cmd;
                1: command_byte = argument[31:24];
                2: command_byte = argument[23:16];
                3: command_byte = argument[15:8];
                4: command_byte = argument[7:0];
                5: command_byte = (cmd == 0) ? 8'h95 :
                                  (cmd == 8) ? 8'h87 : 8'h01;
                default: command_byte = 8'hff;
            endcase
        end
    endfunction

    function [15:0] crc16_byte;
        input [15:0] prior;
        input [7:0] value;
        reg [15:0] c;
        integer i;
        begin
            c = prior;
            for (i = 7; i >= 0; i = i - 1)
                c = (c[15] ^ value[i]) ? {c[14:0], 1'b0} ^ 16'h1021 :
                                          {c[14:0], 1'b0};
            crc16_byte = c;
        end
    endfunction

    // SPI mode 0; 200 kHz during card initialization and 5 MHz afterwards.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_busy <= 0; byte_done <= 0; divider <= 0;
            bit_count <= 0; shift_in <= 0; shift_out <= 0;
            rx_byte <= 0; sck <= 0; mosi <= 1;
        end else begin
            byte_done <= 0;
            if (byte_start && !byte_busy) begin
                byte_busy <= 1;
                divider <= 0; bit_count <= 0; shift_in <= 0;
                shift_out <= tx_byte; mosi <= tx_byte[7]; sck <= 0;
            end else if (byte_busy) begin
                if (divider == (init_done ? 8'd4 : 8'd124)) begin
                    divider <= 0;
                    if (!sck) begin
                        sck <= 1;
                        shift_in <= {shift_in[6:0], miso};
                    end else begin
                        sck <= 0;
                        if (bit_count == 4'd7) begin
                            byte_busy <= 0; byte_done <= 1;
                            rx_byte <= shift_in; mosi <= 1;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                            shift_out <= {shift_out[6:0], 1'b1};
                            mosi <= shift_out[6];
                        end
                    end
                end else divider <= divider + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_DUMMY_START; cs_n <= 1;
            init_done <= 0; done <= 0; error_code <= 0; sector_count <= 0;
            command <= 0; command_lba <= 0; readback <= 0;
            send_index <= 0; extra_index <= 0; extra_value <= 0; ocr <= 0;
            poll_count <= 0; token_count <= 0; busy_count <= 0;
            acmd_retries <= 0; dummy_count <= 0; data_count <= 0;
            csd_c_size <= 0; csd_structure <= 0; crc_calc <= 0; crc_hi <= 0;
            data_mismatch <= 0; crc_low_byte <= 0;
            tx_byte <= 8'hff; byte_start <= 0;
        end else begin
            byte_start <= 0;
            done <= 0;
            case (state)
                S_DUMMY_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_DUMMY_WAIT;
                end
                S_DUMMY_WAIT: if (byte_done) begin
                    if (dummy_count == 4'd9) begin
                        cs_n <= 0; command <= 0; send_index <= 0;
                        state <= S_CMD_START;
                    end else begin
                        dummy_count <= dummy_count + 1'b1;
                        state <= S_DUMMY_START;
                    end
                end
                S_CMD_START: begin
                    tx_byte <= command_byte(command, send_index, command_lba);
                    byte_start <= 1; state <= S_CMD_WAIT;
                end
                S_CMD_WAIT: if (byte_done) begin
                    if (send_index == 3'd5) begin
                        poll_count <= 0; state <= S_RESP_START;
                    end else begin
                        send_index <= send_index + 1'b1; state <= S_CMD_START;
                    end
                end
                S_RESP_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_RESP_WAIT;
                end
                S_RESP_WAIT: if (byte_done) begin
                    if (!rx_byte[7]) begin
                        if ((command == 0 && rx_byte != 8'h01) ||
                            (command == 8 && rx_byte != 8'h01) ||
                            (command == 55 && rx_byte > 8'h01) ||
                            (command == 41 && rx_byte > 8'h01) ||
                            (command == 58 && rx_byte != 8'h00) ||
                            ((command == 9 || command == 17 || command == 24) &&
                             rx_byte != 8'h00)) begin
                            error_code <= 8'h11; done <= init_done;
                            cs_n <= 1; state <= S_FAULT;
                        end else if (command == 8 || command == 58) begin
                            extra_index <= 0; extra_value <= 0;
                            state <= S_EXTRA_START;
                        end else if (command == 9 || command == 17) begin
                            token_count <= 0; state <= S_TOKEN_START;
                        end else if (command == 24) begin
                            data_count <= 0; crc_calc <= 0;
                            state <= S_W_GAP_START;
                        end else if (command == 41 && rx_byte == 8'h01) begin
                            if (acmd_retries == 16'd1000) begin
                                error_code <= 8'h41; cs_n <= 1; state <= S_FAULT;
                            end else begin
                                acmd_retries <= acmd_retries + 1'b1;
                                command <= 55; send_index <= 0; state <= S_CMD_START;
                            end
                        end else begin
                            if (command == 0) command <= 8;
                            else if (command == 8) command <= 55;
                            else if (command == 55) command <= 41;
                            else if (command == 41) command <= 58;
                            send_index <= 0; state <= S_CMD_START;
                        end
                    end else if (poll_count == 5'd31) begin
                        error_code <= 8'h12; done <= init_done;
                        cs_n <= 1; state <= S_FAULT;
                    end else begin
                        poll_count <= poll_count + 1'b1; state <= S_RESP_START;
                    end
                end
                S_EXTRA_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_EXTRA_WAIT;
                end
                S_EXTRA_WAIT: if (byte_done) begin
                    extra_value <= {extra_value[23:0], rx_byte};
                    if (extra_index == 3'd3) begin
                        if (command == 8) begin
                            if ({extra_value[23:0], rx_byte} != 32'h000001AA) begin
                                error_code <= 8'h08; cs_n <= 1; state <= S_FAULT;
                            end else begin
                                command <= 55; send_index <= 0; state <= S_CMD_START;
                            end
                        end else begin
                            ocr <= {extra_value[23:0], rx_byte};
                            // CCS is bit 30, carried in the first R3 byte.
                            if (!extra_value[22]) begin
                                error_code <= 8'h58; cs_n <= 1; state <= S_FAULT;
                            end else begin
                                command <= 9; send_index <= 0; state <= S_CMD_START;
                            end
                        end
                    end else begin
                        extra_index <= extra_index + 1'b1; state <= S_EXTRA_START;
                    end
                end
                S_TOKEN_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_TOKEN_WAIT;
                end
                S_TOKEN_WAIT: if (byte_done) begin
                    if (rx_byte == 8'hfe) begin
                        data_count <= 0; crc_calc <= 0; data_mismatch <= 0;
                        if (command == 9) begin
                            csd_c_size <= 0; csd_structure <= 0;
                        end
                        state <= S_DATA_START;
                    end else if (token_count == 16'd65535) begin
                        error_code <= 8'h21; done <= init_done;
                        cs_n <= 1; state <= S_FAULT;
                    end else begin
                        token_count <= token_count + 1'b1; state <= S_TOKEN_START;
                    end
                end
                S_DATA_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_DATA_WAIT;
                end
                S_DATA_WAIT: if (byte_done) begin
                    if (data_count < ((command == 9) ? 10'd16 : 10'd512)) begin
                        crc_calc <= crc16_byte(crc_calc, rx_byte);
                        if (command == 9) begin
                            if (data_count == 0) csd_structure <= rx_byte[7:6];
                            if (data_count == 7) csd_c_size[21:16] <= rx_byte[5:0];
                            if (data_count == 8) csd_c_size[15:8] <= rx_byte;
                            if (data_count == 9) csd_c_size[7:0] <= rx_byte;
                        end else if (readback) begin
                            if (rx_byte != block_mem[data_count[8:0]])
                                data_mismatch <= 1;
                        end
                    end
                    if (data_count == ((command == 9) ? 10'd16 : 10'd512))
                        crc_hi <= rx_byte;
                    if (data_count == ((command == 9) ? 10'd17 : 10'd513)) begin
                        cs_n <= 1;
                        if (crc_calc != {crc_hi, rx_byte}) begin
                            error_code <= 8'h31; done <= init_done; state <= S_FAULT;
                        end else if (command == 9) begin
                            if (csd_structure != 2'b01 || !ocr[30]) begin
                                error_code <= 8'h09; state <= S_FAULT;
                            end else begin
                                sector_count <= ({10'd0, csd_c_size} + 32'd1) << 10;
                                init_done <= 1; state <= S_IDLE;
                            end
                        end else if (data_mismatch) begin
                            error_code <= 8'h51; done <= 1; state <= S_FAULT;
                        end else begin
                            error_code <= 0; done <= 1; state <= S_IDLE;
                        end
                    end else begin
                        data_count <= data_count + 1'b1; state <= S_DATA_START;
                    end
                end
                S_IDLE: begin
                    cs_n <= 1;
                    if (req_start) begin
                        if (!req_guard_valid || req_lba >= sector_count) begin
                            error_code <= 8'h40; done <= 1;
                        end else begin
                            command_lba <= req_lba;
                            readback <= 0;
                            command <= req_write ? 8'd24 : 8'd17;
                            send_index <= 0; cs_n <= 0;
                            error_code <= 0; state <= S_CMD_START;
                        end
                    end
                end
                S_W_GAP_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_W_GAP_WAIT;
                end
                S_W_GAP_WAIT: if (byte_done) state <= S_W_TOKEN_START;
                S_W_TOKEN_START: begin
                    tx_byte <= 8'hfe; byte_start <= 1; state <= S_W_TOKEN_WAIT;
                end
                S_W_TOKEN_WAIT: if (byte_done) state <= S_W_DATA_START;
                S_W_DATA_START: begin
                    tx_byte <= block_mem[data_count[8:0]];
                    byte_start <= 1; state <= S_W_DATA_WAIT;
                end
                S_W_DATA_WAIT: if (byte_done) begin
                    crc_calc <= crc16_byte(crc_calc, block_mem[data_count[8:0]]);
                    if (data_count == 10'd511) begin
                        crc_low_byte <= 0; state <= S_W_CRC_START;
                    end else begin
                        data_count <= data_count + 1'b1; state <= S_W_DATA_START;
                    end
                end
                S_W_CRC_START: begin
                    tx_byte <= crc_low_byte ? crc_calc[7:0] : crc_calc[15:8];
                    byte_start <= 1; state <= S_W_CRC_WAIT;
                end
                S_W_CRC_WAIT: if (byte_done) begin
                    if (!crc_low_byte) begin
                        crc_low_byte <= 1; state <= S_W_CRC_START;
                    end else begin
                        busy_count <= 0; state <= S_W_RESP_START;
                    end
                end
                S_W_RESP_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_W_RESP_WAIT;
                end
                S_W_RESP_WAIT: if (byte_done) begin
                    if (rx_byte != 8'hff) begin
                        if (rx_byte[4:0] != 5'b00101) begin
                            error_code <= 8'h61; done <= 1;
                            cs_n <= 1; state <= S_FAULT;
                        end else begin
                            busy_count <= 0; state <= S_W_BUSY_START;
                        end
                    end else if (busy_count == 20'd500000) begin
                        error_code <= 8'h71; done <= 1;
                        cs_n <= 1; state <= S_FAULT;
                    end else begin
                        busy_count <= busy_count + 1'b1; state <= S_W_RESP_START;
                    end
                end
                S_W_BUSY_START: begin
                    tx_byte <= 8'hff; byte_start <= 1; state <= S_W_BUSY_WAIT;
                end
                S_W_BUSY_WAIT: if (byte_done) begin
                    if (rx_byte == 8'hff) begin
                        command <= 17; send_index <= 0; readback <= 1;
                        state <= S_CMD_START;
                    end else if (busy_count == 20'd500000) begin
                        error_code <= 8'h81; done <= 1;
                        cs_n <= 1; state <= S_FAULT;
                    end else begin
                        busy_count <= busy_count + 1'b1; state <= S_W_BUSY_START;
                    end
                end
                S_FAULT: cs_n <= 1;
                default: state <= S_FAULT;
            endcase
        end
    end
endmodule
