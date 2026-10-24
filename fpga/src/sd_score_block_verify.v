// Read-only verifier for one score block and its progress log. A block counts
// as recovered only if log identity, record CRC, data CRC and padding all
// match. Invalid content is distinct from SD I/O failure. This module never
// drives block_write and never modifies the card or block buffer.
module sd_score_block_verify (
    input wire clk, input wire rst_n, input wire start,
    input wire [2:0] slot,
    input wire [11:0] block_index,
    input wire [9:0] expected_bytes,
    input wire [127:0] uuid,
    input wire [63:0] slot_epoch,
    input wire [31:0] sector_count,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    output reg block_start, output wire block_write,
    output wire [31:0] block_lba, output wire block_guard_valid,
    output wire [8:0] buffer_addr, input wire [7:0] buffer_rdata,
    output reg done, output reg valid, output reg io_failed
);
    localparam IDLE=0,REQUEST=1,WAIT_BLOCK=2,FETCH_LOG=3,
        READ_LOG=4,CHECK_LOG=5,FETCH_DATA=6,READ_DATA=7,
        CHECK_DATA=8,FINISH=9;
    reg [3:0] state;
    reg data_phase;
    reg [8:0] byte_index;
    reg [2:0] held_slot;
    reg [11:0] held_index;
    reg [9:0] held_bytes;
    reg [127:0] held_uuid;
    reg [63:0] held_epoch;
    reg [31:0] record_crc, saved_record_crc, saved_record_inverse;
    reg [31:0] data_crc, saved_data_crc;
    reg content_ok;
    reg [7:0] byte_value;
    wire [31:0] lba;
    wire lba_valid;
    sd_storage_lba address_guard (
        .region(data_phase ? 2'd1 : 2'd2), .directory_b(1'b0),
        .slot(held_slot), .index({1'b0,held_index}),
        .sector_count(sector_count), .lba(lba), .valid(lba_valid)
    );
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    assign block_write=1'b0;
    assign buffer_addr=byte_index;

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

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; data_phase<=0; byte_index<=0;
            held_slot<=0; held_index<=0; held_bytes<=0;
            held_uuid<=0; held_epoch<=0;
            record_crc<=32'hffffffff; saved_record_crc<=0;
            saved_record_inverse<=0; data_crc<=32'hffffffff;
            saved_data_crc<=0; content_ok<=0; byte_value<=0;
            block_start<=0; done<=0; valid<=0; io_failed<=0;
        end else begin
            block_start<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    valid<=0; io_failed<=0; content_ok<=1;
                    if(slot>=6 || expected_bytes==0 || expected_bytes>512 ||
                       uuid==0 || slot_epoch==0) state<=FINISH;
                    else begin
                        held_slot<=slot; held_index<=block_index;
                        held_bytes<=expected_bytes; held_uuid<=uuid;
                        held_epoch<=slot_epoch;
                        data_phase<=0; byte_index<=0;
                        record_crc<=32'hffffffff;
                        saved_record_crc<=0; saved_record_inverse<=0;
                        saved_data_crc<=0; data_crc<=32'hffffffff;
                        state<=REQUEST;
                    end
                end
                REQUEST: if(block_ready) begin
                    if(!lba_valid) begin io_failed<=1; state<=FINISH; end
                    else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin io_failed<=1; state<=FINISH; end
                    else begin
                        byte_index<=0;
                        state<=data_phase ? FETCH_DATA : FETCH_LOG;
                    end
                end
                FETCH_LOG:begin
                    byte_value<=buffer_rdata;
                    state<=READ_LOG;
                end
                READ_LOG: begin
                    if(byte_index<40)
                        record_crc<=crc_byte(record_crc,byte_value);
                    case(byte_index)
                        0:if(byte_value!="P") content_ok<=0;
                        1:if(byte_value!="S") content_ok<=0;
                        2:if(byte_value!="L") content_ok<=0;
                        3:if(byte_value!="G") content_ok<=0;
                        4:if(byte_value!=1) content_ok<=0;
                        5,34,35:if(byte_value!=0) content_ok<=0;
                        6:if(byte_value!=held_bytes[7:0]) content_ok<=0;
                        7:if(byte_value!={6'd0,held_bytes[9:8]}) content_ok<=0;
                        32:if(byte_value!=held_index[7:0]) content_ok<=0;
                        33:if(byte_value!={4'd0,held_index[11:8]}) content_ok<=0;
                        36:saved_data_crc[7:0]<=byte_value;
                        37:saved_data_crc[15:8]<=byte_value;
                        38:saved_data_crc[23:16]<=byte_value;
                        39:saved_data_crc[31:24]<=byte_value;
                        40:saved_record_crc[7:0]<=byte_value;
                        41:saved_record_crc[15:8]<=byte_value;
                        42:saved_record_crc[23:16]<=byte_value;
                        43:saved_record_crc[31:24]<=byte_value;
                        44:saved_record_inverse[7:0]<=byte_value;
                        45:saved_record_inverse[15:8]<=byte_value;
                        46:saved_record_inverse[23:16]<=byte_value;
                        47:saved_record_inverse[31:24]<=byte_value;
                        default:begin
                            if(byte_index>=8 && byte_index<24 &&
                               byte_value!=held_uuid[127-8*(byte_index-8) -: 8])
                                content_ok<=0;
                            else if(byte_index>=24 && byte_index<32 &&
                                    byte_value!=held_epoch[8*(byte_index-24) +: 8])
                                content_ok<=0;
                            else if(byte_index>=48 && byte_value!=0)
                                content_ok<=0;
                        end
                    endcase
                    if(byte_index==511) state<=CHECK_LOG;
                    else begin byte_index<=byte_index+1'b1; state<=FETCH_LOG; end
                end
                CHECK_LOG: begin
                    if(!content_ok || saved_record_crc!=~record_crc ||
                       saved_record_inverse!=record_crc) state<=FINISH;
                    else begin
                        data_phase<=1; data_crc<=32'hffffffff;
                        state<=REQUEST;
                    end
                end
                FETCH_DATA:begin
                    byte_value<=buffer_rdata;
                    state<=READ_DATA;
                end
                READ_DATA: begin
                    if({1'b0,byte_index}<held_bytes)
                        data_crc<=crc_byte(data_crc,byte_value);
                    else if(byte_value!=0) content_ok<=0;
                    if(byte_index==511) state<=CHECK_DATA;
                    else begin byte_index<=byte_index+1'b1; state<=FETCH_DATA; end
                end
                CHECK_DATA: begin
                    valid<=content_ok && saved_data_crc==~data_crc;
                    state<=FINISH;
                end
                FINISH: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
