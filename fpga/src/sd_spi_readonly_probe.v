// SPI-mode microSD probe. CMD24 exists only behind a debounced KEY1 pulse;
// it overwrites exactly TEST_LBA and never runs automatically after download.
// 50 MHz / (2 * 125) = 200 kHz, below the 400 kHz initialization ceiling.
module sd_spi_readonly_probe (
    input wire clk, input wire rst_n, input wire miso,
    input wire write_test_pulse,
    output reg cs_n, output reg sck, output reg mosi,
    output reg [15:0] status, output reg [31:0] ocr,
    output reg [31:0] sector_count, output reg [31:0] sector_tail
);
    localparam IDLE=0, DUMMY_START=1, DUMMY_WAIT=2,
        CMD_START=3, CMD_WAIT=4, RESP_START=5, RESP_WAIT=6,
        EXTRA_START=7, EXTRA_WAIT=8, TOKEN_START=9, TOKEN_WAIT=10,
        DATA_START=11, DATA_WAIT=12, DONE=13, ERROR=14,
        W_GAP_START=15, W_GAP_WAIT=16, W_TOKEN_START=17, W_TOKEN_WAIT=18,
        W_DATA_START=19, W_DATA_WAIT=20, W_CRC_START=21, W_CRC_WAIT=22,
        W_RESP_START=23, W_RESP_WAIT=24, W_BUSY_START=25, W_BUSY_WAIT=26;
    localparam [31:0] TEST_LBA = 32'h00002000;
    reg [4:0] state;
    reg [7:0] command;
    reg [2:0] test_phase; // 0=LBA0, 4=prior test-sector inspect, 1=write, 2=readback, 3=done
    reg [2:0] send_index, extra_index;
    reg [4:0] poll_count;
    reg [15:0] token_count;
    reg [3:0] dummy_count;
    reg [15:0] acmd_retries;
    reg [9:0] data_count;
    reg [31:0] extra_value;
    reg [7:0] response;
    reg [21:0] csd_c_size;
    reg [1:0] csd_structure;
    reg [15:0] crc_calc;
    reg [7:0] crc_hi;
    reg [15:0] write_wait_count;
    reg crc_low_byte;
    reg data_mismatch;
    reg [7:0] tx_byte;
    reg byte_start;
    reg byte_busy, byte_done;
    reg [7:0] rx_byte, shift_in, shift_out;
    reg [7:0] divider;
    reg [3:0] bit_count;

    function [7:0] command_byte;
        input [7:0] cmd;
        input [2:0] index;
        reg [31:0] argument;
        begin
            argument = ((cmd == 8'd24) ||
                        (cmd == 8'd17 && (test_phase == 2 || test_phase == 4))) ?
                       TEST_LBA : (cmd == 8'd41) ? 32'h40000000 :
                       (cmd == 8'd8) ? 32'h000001AA : 32'h00000000;
            case (index)
                0: command_byte = 8'h40 | cmd;
                1: command_byte = argument[31:24];
                2: command_byte = argument[23:16];
                3: command_byte = argument[15:8];
                4: command_byte = argument[7:0];
                5: command_byte = (cmd == 8'd0) ? 8'h95 :
                                  (cmd == 8'd8) ? 8'h87 : 8'h01;
                default: command_byte = 8'hFF;
            endcase
        end
    endfunction

    function [7:0] test_pattern;
        input [9:0] index;
        begin
            test_pattern = (index[7:0] * 8'd37) ^ 8'hA5;
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

    // SPI mode 0: data changes while clock is low, sampled on rising edge.
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
                if (divider == 8'd124) begin
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
            state <= IDLE; cs_n <= 1; status <= 16'h1000;
            ocr <= 0; sector_count <= 0; sector_tail <= 0; command <= 0;
            test_phase <= 0; write_wait_count <= 0;
            crc_low_byte <= 0; data_mismatch <= 0;
            send_index <= 0; extra_index <= 0; poll_count <= 0;
            dummy_count <= 0; acmd_retries <= 0; data_count <= 0; token_count <= 0;
            extra_value <= 0; response <= 0; tx_byte <= 8'hFF;
            csd_c_size <= 0; csd_structure <= 0; crc_calc <= 0; crc_hi <= 0;
            byte_start <= 0;
        end else begin
            byte_start <= 0;
            case (state)
                IDLE: begin cs_n <= 1; state <= DUMMY_START; end
                DUMMY_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= DUMMY_WAIT;
                end
                DUMMY_WAIT: if (byte_done) begin
                    if (dummy_count == 4'd9) begin
                        cs_n <= 0; command <= 0; send_index <= 0;
                        status <= 16'h2000; state <= CMD_START;
                    end else begin
                        dummy_count <= dummy_count + 1'b1;
                        state <= DUMMY_START;
                    end
                end
                CMD_START: begin
                    tx_byte <= command_byte(command, send_index);
                    byte_start <= 1; state <= CMD_WAIT;
                end
                CMD_WAIT: if (byte_done) begin
                    if (send_index == 3'd5) begin
                        poll_count <= 0; state <= RESP_START;
                    end else begin
                        send_index <= send_index + 1'b1;
                        state <= CMD_START;
                    end
                end
                RESP_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= RESP_WAIT;
                end
                RESP_WAIT: if (byte_done) begin
                    if (!rx_byte[7]) begin
                        response <= rx_byte;
                        if ((command == 0 && rx_byte != 8'h01) ||
                            (command == 8 && rx_byte != 8'h01) ||
                            (command == 55 && rx_byte > 8'h01) ||
                            (command == 41 && rx_byte > 8'h01) ||
                            (command == 58 && rx_byte != 8'h00) ||
                            ((command == 9 || command == 17 || command == 24) &&
                             rx_byte != 8'h00)) begin
                            status <= 16'hE100 | {8'd0, command}; state <= ERROR;
                        end else if (command == 8 || command == 58) begin
                            extra_index <= 0; extra_value <= 0;
                            state <= EXTRA_START;
                        end else if (command == 9 || command == 17) begin
                            token_count <= 0; state <= TOKEN_START;
                        end else if (command == 24) begin
                            data_count <= 0; crc_calc <= 0;
                            status <= 16'hA100; state <= W_GAP_START;
                        end else if (command == 41 && rx_byte == 8'h01) begin
                            if (acmd_retries == 16'd1000) begin
                                status <= 16'hE041; state <= ERROR;
                            end else begin
                                acmd_retries <= acmd_retries + 1'b1;
                                command <= 55; send_index <= 0; state <= CMD_START;
                            end
                        end else begin
                            if (command == 0) begin command <= 8; status <= 16'h3000; end
                            else if (command == 8) begin command <= 55; status <= 16'h4000; end
                            else if (command == 55) command <= 41;
                            else if (command == 41) begin command <= 58; status <= 16'h5000; end
                            send_index <= 0; state <= CMD_START;
                        end
                    end else if (poll_count == 5'd31) begin
                        status <= 16'hE200 | {8'd0, command}; state <= ERROR;
                    end else begin
                        poll_count <= poll_count + 1'b1; state <= RESP_START;
                    end
                end
                EXTRA_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= EXTRA_WAIT;
                end
                EXTRA_WAIT: if (byte_done) begin
                    extra_value <= {extra_value[23:0], rx_byte};
                    if (extra_index == 3'd3) begin
                        if (command == 8) begin
                            if ({extra_value[23:0], rx_byte} != 32'h000001AA) begin
                                status <= 16'hE008; state <= ERROR;
                            end else begin
                                command <= 55; send_index <= 0;
                                status <= 16'h4000; state <= CMD_START;
                            end
                        end else begin
                            ocr <= {extra_value[23:0], rx_byte};
                            command <= 9; send_index <= 0;
                            status <= 16'h6000; state <= CMD_START;
                        end
                    end else begin
                        extra_index <= extra_index + 1'b1; state <= EXTRA_START;
                    end
                end
                TOKEN_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= TOKEN_WAIT;
                end
                TOKEN_WAIT: if (byte_done) begin
                    if (rx_byte == 8'hFE) begin
                        data_count <= 0; crc_calc <= 0;
                        if (command == 9) begin
                            csd_c_size <= 0; csd_structure <= 0;
                        end else if (test_phase == 0) sector_tail <= 0;
                        else data_mismatch <= 0;
                        status <= 16'h7000; state <= DATA_START;
                    end else if (token_count == 16'd25000) begin
                        status <= 16'hE000 | {8'd0, command}; state <= ERROR;
                    end else begin
                        token_count <= token_count + 1'b1; state <= TOKEN_START;
                    end
                end
                DATA_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= DATA_WAIT;
                end
                DATA_WAIT: if (byte_done) begin
                    if (data_count < ((command == 9) ? 10'd16 : 10'd512)) begin
                        crc_calc <= crc16_byte(crc_calc, rx_byte);
                        if (command == 9) begin
                            if (data_count == 0) csd_structure <= rx_byte[7:6];
                            if (data_count == 7) csd_c_size[21:16] <= rx_byte[5:0];
                            if (data_count == 8) csd_c_size[15:8] <= rx_byte;
                            if (data_count == 9) csd_c_size[7:0] <= rx_byte;
                        end else if (test_phase == 0) begin
                            if (data_count >= 10'd508)
                                sector_tail <= {sector_tail[23:0], rx_byte};
                        end else if (rx_byte != test_pattern(data_count))
                            data_mismatch <= 1;
                    end
                    if (data_count == ((command == 9) ? 10'd16 : 10'd512))
                        crc_hi <= rx_byte;
                    if (data_count == ((command == 9) ? 10'd17 : 10'd513)) begin
                        if (crc_calc != {crc_hi, rx_byte}) begin
                            status <= 16'hE300 | {8'd0, command}; state <= ERROR;
                        end else if (command == 9) begin
                            if (csd_structure != 2'b01 || ocr[30] != 1'b1) begin
                                status <= 16'hE409; state <= ERROR;
                            end else if ((({10'd0, csd_c_size} + 32'd1) << 10)
                                         <= TEST_LBA) begin
                                status <= 16'hE419; state <= ERROR;
                            end else begin
                                sector_count <= ({10'd0, csd_c_size} + 32'd1) << 10;
                                command <= 17; send_index <= 0;
                                status <= 16'h6000; state <= CMD_START;
                            end
                        end else if (test_phase == 0) begin
                            if (sector_tail[15:0] == 16'h55AA) begin
                                test_phase <= 4; command <= 17; send_index <= 0;
                                status <= 16'hA400; state <= CMD_START;
                            end else begin
                                cs_n <= 1; status <= 16'hD017; state <= DONE;
                            end
                        end else if (test_phase == 4) begin
                            cs_n <= 1;
                            status <= data_mismatch ? 16'hD0AA : 16'hD124;
                            state <= DONE;
                        end else begin
                            cs_n <= 1;
                            status <= data_mismatch ? 16'hE511 : 16'hD124;
                            test_phase <= 3;
                            state <= data_mismatch ? ERROR : DONE;
                        end
                    end else begin
                        data_count <= data_count + 1'b1; state <= DATA_START;
                    end
                end
                DONE: begin
                    cs_n <= 1;
                    if (test_phase == 4 &&
                        (status == 16'hD0AA || status == 16'hD124) &&
                        sector_count > TEST_LBA &&
                        write_test_pulse) begin
                        test_phase <= 1; command <= 24; send_index <= 0;
                        cs_n <= 0; status <= 16'hA000; state <= CMD_START;
                    end
                end
                W_GAP_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= W_GAP_WAIT;
                end
                W_GAP_WAIT: if (byte_done) state <= W_TOKEN_START;
                W_TOKEN_START: begin
                    tx_byte <= 8'hFE; byte_start <= 1; state <= W_TOKEN_WAIT;
                end
                W_TOKEN_WAIT: if (byte_done) state <= W_DATA_START;
                W_DATA_START: begin
                    tx_byte <= test_pattern(data_count);
                    byte_start <= 1; state <= W_DATA_WAIT;
                end
                W_DATA_WAIT: if (byte_done) begin
                    crc_calc <= crc16_byte(crc_calc, test_pattern(data_count));
                    if (data_count == 10'd511) begin
                        crc_low_byte <= 0; state <= W_CRC_START;
                    end else begin
                        data_count <= data_count + 1'b1; state <= W_DATA_START;
                    end
                end
                W_CRC_START: begin
                    tx_byte <= crc_low_byte ? crc_calc[7:0] : crc_calc[15:8];
                    byte_start <= 1; state <= W_CRC_WAIT;
                end
                W_CRC_WAIT: if (byte_done) begin
                    if (!crc_low_byte) begin
                        crc_low_byte <= 1; state <= W_CRC_START;
                    end else begin
                        write_wait_count <= 0; state <= W_RESP_START;
                    end
                end
                W_RESP_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= W_RESP_WAIT;
                end
                W_RESP_WAIT: if (byte_done) begin
                    if (rx_byte != 8'hFF) begin
                        if (rx_byte[4:0] != 5'b00101) begin
                            status <= 16'hE618; state <= ERROR;
                        end else begin
                            write_wait_count <= 0; state <= W_BUSY_START;
                        end
                    end else if (write_wait_count == 16'd25000) begin
                        status <= 16'hE718; state <= ERROR;
                    end else begin
                        write_wait_count <= write_wait_count + 1'b1;
                        state <= W_RESP_START;
                    end
                end
                W_BUSY_START: begin
                    tx_byte <= 8'hFF; byte_start <= 1; state <= W_BUSY_WAIT;
                end
                W_BUSY_WAIT: if (byte_done) begin
                    if (rx_byte == 8'hFF) begin
                        command <= 17; send_index <= 0; test_phase <= 2;
                        status <= 16'hA200; state <= CMD_START;
                    end else if (write_wait_count == 16'd25000) begin
                        status <= 16'hE818; state <= ERROR;
                    end else begin
                        write_wait_count <= write_wait_count + 1'b1;
                        state <= W_BUSY_START;
                    end
                end
                ERROR: cs_n <= 1;
                default: state <= ERROR;
            endcase
        end
    end
endmodule
