// Read one fixed-stride (448-byte) directory entry from an already CRC-validated
// directory copy. This module is read-only. Mount/CRC validation remains the
// caller's responsibility; only `valid` metadata may feed LIST or recovery.
module sd_directory_entry_read (
    input wire clk, input wire rst_n, input wire start,
    input wire directory_b, input wire [2:0] entry_index,
    input wire [2:0] entry_count, input wire [31:0] sector_count,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    output reg block_start, output wire [31:0] block_lba,
    output wire block_guard_valid, output wire [8:0] buffer_addr,
    input wire [7:0] buffer_rdata,
    input wire [8:0] title_addr, output wire [7:0] title_byte,
    output reg done, output reg valid, output reg io_failed,
    output reg [127:0] uuid, output reg [7:0] entry_state,
    output reg [15:0] title_len, output reg [31:0] total_bytes,
    output reg [31:0] file_crc, output reg [31:0] capabilities,
    output reg [31:0] total_blocks, output reg [63:0] slot_epoch
);
    localparam IDLE=0,REQUEST=1,WAIT_BLOCK=2,READ_BYTE=3,FINISH=4;
    reg [2:0] state;
    reg held_b;
    reg requested_exists;
    reg [2:0] sector_index;
    reg [8:0] byte_index;
    reg [8:0] entry_offset;
    reg [15:0] block_bytes,package_major;
    reg reserved_ok,title_ok;
    reg [7:0] title_mem[0:383];
    wire [31:0] lba;
    wire lba_valid;
    wire [11:0] entry_base=12'd16+({9'd0,entry_index}*12'd448);
    assign buffer_addr=byte_index;
    assign title_byte=(title_addr<9'd384) ? title_mem[title_addr] : 8'd0;
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    sd_storage_lba address_guard (
        .region(2'd0),.directory_b(held_b),.slot(3'd0),
        .index({10'd0,sector_index}),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; held_b<=0; requested_exists<=0; sector_index<=0;
            byte_index<=0; entry_offset<=0; block_start<=0;
            done<=0; valid<=0; io_failed<=0; uuid<=0;
            entry_state<=0; title_len<=0; total_bytes<=0;
            file_crc<=0; capabilities<=0; total_blocks<=0;
            slot_epoch<=0; block_bytes<=0; package_major<=0;
            reserved_ok<=0; title_ok<=0;
        end else begin
            block_start<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    valid<=0; io_failed<=0; uuid<=0; entry_state<=0;
                    title_len<=0; total_bytes<=0; file_crc<=0;
                    capabilities<=0; total_blocks<=0; slot_epoch<=0;
                    block_bytes<=0; package_major<=0;
                    reserved_ok<=1; title_ok<=1; entry_offset<=0;
                    held_b<=directory_b;
                    requested_exists<=entry_index<entry_count && entry_index<3'd6;
                    sector_index<=entry_base[11:9];
                    byte_index<=entry_base[8:0];
                    if(entry_index>=entry_count || entry_index>=3'd6)
                        state<=FINISH;
                    else state<=REQUEST;
                end
                REQUEST: if(block_ready) begin
                    if(!lba_valid) begin io_failed<=1; state<=FINISH; end
                    else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin io_failed<=1; state<=FINISH; end
                    else state<=READ_BYTE;
                end
                READ_BYTE: begin
                    if(entry_offset<16) uuid[127-8*entry_offset -: 8]<=buffer_rdata;
                    else case(entry_offset)
                        16:entry_state<=buffer_rdata;
                        17:if(buffer_rdata!=0) reserved_ok<=0;
                        18:title_len[7:0]<=buffer_rdata;
                        19:title_len[15:8]<=buffer_rdata;
                        20:total_bytes[7:0]<=buffer_rdata;
                        21:total_bytes[15:8]<=buffer_rdata;
                        22:total_bytes[23:16]<=buffer_rdata;
                        23:total_bytes[31:24]<=buffer_rdata;
                        24:file_crc[7:0]<=buffer_rdata;
                        25:file_crc[15:8]<=buffer_rdata;
                        26:file_crc[23:16]<=buffer_rdata;
                        27:file_crc[31:24]<=buffer_rdata;
                        28:capabilities[7:0]<=buffer_rdata;
                        29:capabilities[15:8]<=buffer_rdata;
                        30:capabilities[23:16]<=buffer_rdata;
                        31:capabilities[31:24]<=buffer_rdata;
                        32:total_blocks[7:0]<=buffer_rdata;
                        33:total_blocks[15:8]<=buffer_rdata;
                        34:total_blocks[23:16]<=buffer_rdata;
                        35:total_blocks[31:24]<=buffer_rdata;
                        36:block_bytes[7:0]<=buffer_rdata;
                        37:block_bytes[15:8]<=buffer_rdata;
                        38:package_major[7:0]<=buffer_rdata;
                        39:package_major[15:8]<=buffer_rdata;
                        40,41,42,43,44,45,46,47:
                            slot_epoch[8*(entry_offset-40) +: 8]<=buffer_rdata;
                        default: begin
                            if(entry_offset<48 && buffer_rdata!=0) reserved_ok<=0;
                            if(entry_offset>=48) begin
                                if(entry_offset<9'd432)
                                    title_mem[entry_offset-48]<=buffer_rdata;
                                if(entry_offset-48<title_len) begin
                                    if(buffer_rdata==0 || buffer_rdata<8'h20)
                                        title_ok<=0;
                                end else if(buffer_rdata!=0) title_ok<=0;
                            end
                        end
                    endcase
                    if(entry_offset==9'd447) state<=FINISH;
                    else begin
                        entry_offset<=entry_offset+1'b1;
                        if(byte_index==9'd511) begin
                            sector_index<=sector_index+1'b1;
                            byte_index<=0; state<=REQUEST;
                        end else byte_index<=byte_index+1'b1;
                    end
                end
                FINISH: begin
                    if(!io_failed && requested_exists && reserved_ok && title_ok &&
                       uuid!=0 && (entry_state==1 || entry_state==2) &&
                       title_len>=1 && title_len<=384 &&
                       total_bytes>=1 && total_bytes<=32'd2097152 &&
                       total_blocks==((total_bytes+32'd511)>>9) &&
                       block_bytes==16'd512 && package_major==16'd2 &&
                       slot_epoch!=0)
                        valid<=1;
                    done<=1; state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
