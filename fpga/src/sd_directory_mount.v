// Read-only validator for two eight-sector directory copies. It never writes.
// Header: "PSDL", version=1 u16 LE, reserved=0 u16, generation u32 LE,
// entry_count u8 (0..6), reserved[3]=0. The first seven sectors are CRC32'd.
// Commit sector: "PSDC", generation u32 LE, CRC32/ISO-HDLC u32 LE,
// bitwise-inverse CRC u32 LE. A copy is valid only if all fields match.
module sd_directory_mount #(
    parameter MAX_ENTRIES=6
) (
    input wire clk, input wire rst_n, input wire start,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    input wire [31:0] sector_count,
    output reg block_start, output wire [31:0] block_lba,
    output wire block_guard_valid, output wire [8:0] buffer_addr,
    input wire [7:0] buffer_rdata,
    output reg done, output reg mounted, output reg io_error,
    output reg blank_media,
    output reg [31:0] generation, output reg [2:0] entry_count,
    output reg a_valid, output reg b_valid,
    output reg [31:0] a_generation, output reg [31:0] b_generation,
    output reg [2:0] a_entry_count, output reg [2:0] b_entry_count
);
    localparam S_IDLE=0,S_REQUEST=1,S_WAIT=2,S_BYTE=3,
        S_NEXT_SECTOR=4,S_FINISH_COPY=5,S_DONE=6,S_PREFETCH=7;
    reg [2:0] state;
    reg copy_b;
    reg [2:0] sector_index;
    reg [8:0] byte_index;
    reg [31:0] crc, header_generation, commit_generation;
    reg [31:0] commit_crc, commit_inverse;
    reg [2:0] header_count;
    reg header_ok, commit_ok;
    reg [7:0] sampled_byte;
    wire [31:0] next_lba;
    wire lba_valid;
    sd_storage_lba address_guard (
        .region(2'd0), .directory_b(copy_b), .slot(3'd0),
        .index({10'd0,sector_index}), .sector_count(sector_count),
        .lba(next_lba), .valid(lba_valid)
    );
    assign block_lba=next_lba;
    assign block_guard_valid=lba_valid;
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
    wire copy_valid=header_ok && commit_ok &&
        header_generation!=0 && header_generation==commit_generation &&
        commit_crc==~crc && commit_inverse==~commit_crc;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=S_IDLE; copy_b<=0; sector_index<=0; byte_index<=0;
            crc<=32'hffffffff; header_generation<=0; commit_generation<=0;
            commit_crc<=0; commit_inverse<=0; header_count<=0;
            header_ok<=1; commit_ok<=1; block_start<=0;
            sampled_byte<=0;
            done<=0; mounted<=0; io_error<=0; blank_media<=1;
            generation<=0; entry_count<=0;
            a_valid<=0; b_valid<=0; a_generation<=0; b_generation<=0;
            a_entry_count<=0; b_entry_count<=0;
        end else begin
            block_start<=0; done<=0;
            case(state)
                S_IDLE: if(start) begin
                    copy_b<=0; sector_index<=0; byte_index<=0;
                    crc<=32'hffffffff; header_generation<=0; commit_generation<=0;
                    commit_crc<=0; commit_inverse<=0; header_count<=0;
                    header_ok<=1; commit_ok<=1;
                    mounted<=0; io_error<=0; blank_media<=1;
                    generation<=0; entry_count<=0;
                    a_valid<=0; b_valid<=0; a_generation<=0; b_generation<=0;
                    a_entry_count<=0; b_entry_count<=0;
                    state<=S_REQUEST;
                end
                S_REQUEST: if(block_ready) begin
                    if(!lba_valid) begin io_error<=1; state<=S_FINISH_COPY; end
                    else begin block_start<=1; state<=S_WAIT; end
                end
                S_WAIT: if(block_done) begin
                    if(block_error!=0) begin io_error<=1; state<=S_FINISH_COPY; end
                    else begin byte_index<=0; state<=S_PREFETCH; end
                end
                // Break the owner/address -> block RAM -> header comparator
                // path. The buffer address is stable for a full clock before
                // this sample, including at the start of each sector.
                S_PREFETCH: begin sampled_byte<=buffer_rdata; state<=S_BYTE; end
                S_BYTE: begin
                    if(sampled_byte!=8'h00 && sampled_byte!=8'hff)
                        blank_media<=0;
                    if(sector_index!=7) crc<=crc_byte(crc,sampled_byte);
                    if(sector_index==0) begin
                        case(byte_index)
                            0: if(sampled_byte!=8'h50) header_ok<=0;
                            1: if(sampled_byte!=8'h53) header_ok<=0;
                            2: if(sampled_byte!=8'h44) header_ok<=0;
                            3: if(sampled_byte!=8'h4c) header_ok<=0;
                            4: if(sampled_byte!=8'h01) header_ok<=0;
                            5,6,7,13,14,15: if(sampled_byte!=0) header_ok<=0;
                            8: header_generation[7:0]<=sampled_byte;
                            9: header_generation[15:8]<=sampled_byte;
                            10: header_generation[23:16]<=sampled_byte;
                            11: header_generation[31:24]<=sampled_byte;
                            12: begin
                                header_count<=sampled_byte[2:0];
                                if(sampled_byte>MAX_ENTRIES) header_ok<=0;
                            end
                            default: begin end
                        endcase
                    end else if(sector_index==7) begin
                        case(byte_index)
                            0: if(sampled_byte!=8'h50) commit_ok<=0;
                            1: if(sampled_byte!=8'h53) commit_ok<=0;
                            2: if(sampled_byte!=8'h44) commit_ok<=0;
                            3: if(sampled_byte!=8'h43) commit_ok<=0;
                            4: commit_generation[7:0]<=sampled_byte;
                            5: commit_generation[15:8]<=sampled_byte;
                            6: commit_generation[23:16]<=sampled_byte;
                            7: commit_generation[31:24]<=sampled_byte;
                            8: commit_crc[7:0]<=sampled_byte;
                            9: commit_crc[15:8]<=sampled_byte;
                            10: commit_crc[23:16]<=sampled_byte;
                            11: commit_crc[31:24]<=sampled_byte;
                            12: commit_inverse[7:0]<=sampled_byte;
                            13: commit_inverse[15:8]<=sampled_byte;
                            14: commit_inverse[23:16]<=sampled_byte;
                            15: commit_inverse[31:24]<=sampled_byte;
                            default: if(sampled_byte!=0) commit_ok<=0;
                        endcase
                    end
                    if(byte_index==9'd511) state<=S_NEXT_SECTOR;
                    else begin byte_index<=byte_index+1'b1; state<=S_PREFETCH; end
                end
                S_NEXT_SECTOR: begin
                    if(sector_index==7) state<=S_FINISH_COPY;
                    else begin sector_index<=sector_index+1'b1; state<=S_REQUEST; end
                end
                S_FINISH_COPY: begin
                    if(copy_b) begin
                        b_valid<=copy_valid;
                        b_generation<=copy_valid ? header_generation : 0;
                        b_entry_count<=copy_valid ? header_count : 0;
                    end else begin
                        a_valid<=copy_valid;
                        a_generation<=copy_valid ? header_generation : 0;
                        a_entry_count<=copy_valid ? header_count : 0;
                    end
                    if(copy_valid && (!mounted || header_generation>generation)) begin
                        mounted<=1; generation<=header_generation;
                        entry_count<=header_count;
                    end
                    if(copy_b) state<=S_DONE;
                    else begin
                        copy_b<=1; sector_index<=0; byte_index<=0;
                        crc<=32'hffffffff; header_generation<=0; commit_generation<=0;
                        commit_crc<=0; commit_inverse<=0; header_count<=0;
                        header_ok<=1; commit_ok<=1; state<=S_REQUEST;
                    end
                end
                S_DONE: begin done<=1; state<=S_IDLE; end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
