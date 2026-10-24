// Write one score DATA block and its durable progress record, in that order.
// The caller keeps stage_byte stable for each stage_addr and may acknowledge
// DATA only after done && !failed. The SD block device must read back each
// write before raising block_done. This module does not publish directory
// entries or infer progress on reboot.
module sd_score_block_write (
    input wire clk, input wire rst_n, input wire start,
    input wire [2:0] slot,
    input wire [11:0] block_index,
    input wire [9:0] valid_bytes,
    input wire [127:0] uuid,
    input wire [63:0] slot_epoch,
    input wire [31:0] sector_count,
    output wire [8:0] stage_addr,
    input wire [7:0] stage_byte,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    output reg block_start, output wire block_write,
    output wire [31:0] block_lba, output wire block_guard_valid,
    output reg buffer_we, output reg [8:0] buffer_addr,
    output reg [7:0] buffer_wdata,
    output reg done, output reg failed
);
    localparam IDLE=0,FILL_DATA=1,REQUEST=2,WAIT_BLOCK=3,
        FILL_LOG=4,FINISH=5,FAIL=6,FILL_DATA_PREFETCH=7;
    reg [2:0] state;
    reg log_phase;
    reg [8:0] byte_index;
    reg [31:0] data_crc, log_crc;
    reg [2:0] held_slot;
    reg [11:0] held_index;
    reg [9:0] held_bytes;
    reg [127:0] held_uuid;
    reg [63:0] held_epoch;
    wire [31:0] lba;
    wire lba_valid;
    sd_storage_lba address_guard (
        .region(log_phase ? 2'd2 : 2'd1), .directory_b(1'b0),
        .slot(held_slot), .index({1'b0,held_index}),
        .sector_count(sector_count), .lba(lba), .valid(lba_valid)
    );
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    assign block_write=1'b1;
    assign stage_addr=byte_index;

    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer i;
        begin
            c=previous^{24'd0,octet};
            for(i=0;i<8;i=i+1)
                c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction

    // Record v1, one 512-byte sector: PSLG, version, length, UUID, epoch,
    // index, data CRC, record CRC and its complement; zero-filled tail.
    function [7:0] log_byte;
        input [8:0] address;
        input [127:0] id;
        input [63:0] epoch;
        input [11:0] index;
        input [9:0] length;
        input [31:0] payload_crc;
        input [31:0] header_crc;
        begin
            log_byte=0;
            case(address)
                0:log_byte="P"; 1:log_byte="S";
                2:log_byte="L"; 3:log_byte="G";
                4:log_byte=1;
                6:log_byte=length[7:0];
                7:log_byte={6'd0,length[9:8]};
                32:log_byte=index[7:0];
                33:log_byte={4'd0,index[11:8]};
                36:log_byte=payload_crc[7:0];
                37:log_byte=payload_crc[15:8];
                38:log_byte=payload_crc[23:16];
                39:log_byte=payload_crc[31:24];
                40:log_byte=~header_crc[7:0];
                41:log_byte=~header_crc[15:8];
                42:log_byte=~header_crc[23:16];
                43:log_byte=~header_crc[31:24];
                44:log_byte=header_crc[7:0];
                45:log_byte=header_crc[15:8];
                46:log_byte=header_crc[23:16];
                47:log_byte=header_crc[31:24];
                default: begin
                    if(address>=8 && address<24)
                        log_byte=id[127-8*(address-8) -: 8];
                    else if(address>=24 && address<32)
                        log_byte=epoch[8*(address-24) +: 8];
                end
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; log_phase<=0; byte_index<=0;
            held_slot<=0; held_index<=0; held_bytes<=0;
            held_uuid<=0; held_epoch<=0;
            data_crc<=32'hffffffff; log_crc<=32'hffffffff;
            block_start<=0; buffer_we<=0; buffer_addr<=0;
            buffer_wdata<=0; done<=0; failed<=0;
        end else begin
            block_start<=0; buffer_we<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    failed<=0;
                    if(slot>=6 || valid_bytes==0 || valid_bytes>512 ||
                       uuid==0 || slot_epoch==0) begin
                        failed<=1; state<=FAIL;
                    end else begin
                        held_slot<=slot; held_index<=block_index;
                        held_bytes<=valid_bytes; held_uuid<=uuid;
                        held_epoch<=slot_epoch;
                        log_phase<=0; byte_index<=0;
                        data_crc<=32'hffffffff; log_crc<=32'hffffffff;
                        state<=FILL_DATA_PREFETCH;
                    end
                end
                FILL_DATA_PREFETCH: if(block_ready)
                    state<=FILL_DATA;
                FILL_DATA: if(block_ready) begin
                    buffer_we<=1; buffer_addr<=byte_index;
                    buffer_wdata<=({1'b0,byte_index}<held_bytes) ? stage_byte : 0;
                    if({1'b0,byte_index}<held_bytes)
                        data_crc<=crc_byte(data_crc,stage_byte);
                    if(byte_index==511) state<=REQUEST;
                    else begin
                        byte_index<=byte_index+1'b1;
                        state<=FILL_DATA_PREFETCH;
                    end
                end
                FILL_LOG: if(block_ready) begin
                    buffer_we<=1; buffer_addr<=byte_index;
                    buffer_wdata<=log_byte(byte_index,held_uuid,held_epoch,
                        held_index,held_bytes,~data_crc,log_crc);
                    if(byte_index<40)
                        log_crc<=crc_byte(log_crc,log_byte(byte_index,
                            held_uuid,held_epoch,held_index,held_bytes,
                            ~data_crc,log_crc));
                    if(byte_index==511) state<=REQUEST;
                    else byte_index<=byte_index+1'b1;
                end
                REQUEST: begin
                    if(!block_ready || !lba_valid) begin
                        failed<=1; state<=FAIL;
                    end else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin failed<=1; state<=FAIL; end
                    else if(!log_phase) begin
                        log_phase<=1; byte_index<=0; state<=FILL_LOG;
                    end else state<=FINISH;
                end
                FINISH: begin done<=1; state<=IDLE; end
                FAIL: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
