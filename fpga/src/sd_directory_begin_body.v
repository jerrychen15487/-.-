// Directory body for a single, already-validated BEGIN record in slot zero.
// The caller must validate the protocol payload and choose a fresh epoch.
// Addresses 0..15 are supplied by sd_directory_copy_write as its header.
module sd_directory_begin_body (
    input wire [11:0] source_addr,
    input wire [127:0] uuid,
    input wire [31:0] total_bytes, file_crc, capabilities, total_blocks,
    input wire [63:0] slot_epoch,
    input wire [15:0] title_len,
    output wire [8:0] title_addr,
    input wire [7:0] title_byte,
    output reg [7:0] source_byte
);
    wire [11:0] entry_offset=source_addr-12'd16;
    assign title_addr=(entry_offset>=12'd48 && entry_offset<12'd432) ?
        entry_offset[8:0]-9'd48 : 9'd0;
    always @* begin
        source_byte=0;
        if(source_addr>=12'd16 && source_addr<12'd464) begin
            if(entry_offset<12'd16)
                source_byte=uuid[127-8*entry_offset -: 8];
            else case(entry_offset)
                16:source_byte=8'd1; // incomplete, not selectable
                18:source_byte=title_len[7:0];
                19:source_byte=title_len[15:8];
                20:source_byte=total_bytes[7:0];
                21:source_byte=total_bytes[15:8];
                22:source_byte=total_bytes[23:16];
                23:source_byte=total_bytes[31:24];
                24:source_byte=file_crc[7:0];
                25:source_byte=file_crc[15:8];
                26:source_byte=file_crc[23:16];
                27:source_byte=file_crc[31:24];
                28:source_byte=capabilities[7:0];
                29:source_byte=capabilities[15:8];
                30:source_byte=capabilities[23:16];
                31:source_byte=capabilities[31:24];
                32:source_byte=total_blocks[7:0];
                33:source_byte=total_blocks[15:8];
                34:source_byte=total_blocks[23:16];
                35:source_byte=total_blocks[31:24];
                36:source_byte=8'd0; // block_bytes = 512
                37:source_byte=8'd2;
                38:source_byte=8'd2; // package_major = 2
                39:source_byte=8'd0;
                40,41,42,43,44,45,46,47:
                    source_byte=slot_epoch[8*(entry_offset-40) +: 8];
                default: if(entry_offset>=12'd48 &&
                            entry_offset<12'd48+title_len)
                    source_byte=title_byte;
            endcase
        end
    end
endmodule
