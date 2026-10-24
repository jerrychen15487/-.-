// Locate the requested zero-based staff (1) or jianpu (2) PAGE in a
// committed PSC2 file; wrap to the first valid page at end of scan.
// Feed header, all descriptors and PAGE bytes in ascending file-offset order;
// other sections may be skipped. This module only returns an absolute bitmap
// span. SD access, page buffering and HDMI rendering belong to the caller.
module psc2_page_index (
    input wire clk,rst_n,clear,
    input wire [1:0] notation,
    input wire [5:0] target_index,
    input wire scan_done,
    input wire byte_valid,
    input wire [31:0] byte_offset,
    input wire [7:0] byte_data,
    output reg page_found,
    // Sticky once the last PAGE descriptor byte has been consumed. A missing
    // target can then wrap without scanning the much larger BITMAP section.
    output reg page_scan_complete,
    output reg [31:0] page_id,bitmap_offset,
    output reg [5:0] selected_index,
    output reg [31:0] bitmap_length,
    // First successful PAGE publication, retained until hardware reset.
    output reg diag_pub_valid,
    output reg [31:0] diag_pub_length,diag_pub_byte_offset,
    output reg [4:0] diag_pub_page_field
);
    reg [15:0] section_count;
    reg [31:0] desc_type,desc_offset,desc_length,desc_count;
    reg [15:0] desc_profile,desc_record_bytes;
    reg [31:0] page_base,page_end,bitmap_base,bitmap_end;
    reg [4:0] page_field;
    reg [31:0] pending_id,pending_bitmap_offset,pending_bitmap_length;
    reg [15:0] pending_profile,pending_width,pending_height,pending_stride;
    reg [7:0] pending_notation,pending_format;
    reg [5:0] valid_index;
    reg first_valid;
    reg [31:0] first_id,first_bitmap_offset;
    wire [31:0] descriptor_end=32'd64+({16'd0,section_count}<<5);
    wire in_descriptor=byte_offset>=32'd64 &&
        byte_offset<descriptor_end;
    wire [4:0] descriptor_field=(byte_offset-32'd64) & 32'd31;
    wire in_page=byte_offset>=page_base && byte_offset<page_end;
    wire [31:0] completed_length={byte_data,pending_bitmap_length[23:0]};

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            section_count<=0;desc_type<=0;desc_offset<=0;
            desc_length<=0;desc_count<=0;desc_profile<=0;
            desc_record_bytes<=0;page_base<=0;page_end<=0;
            bitmap_base<=0;bitmap_end<=0;page_field<=0;
            pending_id<=0;pending_bitmap_offset<=0;
            pending_bitmap_length<=0;pending_profile<=0;
            pending_width<=0;pending_height<=0;pending_stride<=0;
            pending_notation<=0;pending_format<=0;
            page_found<=0;page_scan_complete<=0;
            page_id<=0;bitmap_offset<=0;
            selected_index<=0;valid_index<=0;first_valid<=0;
            first_id<=0;first_bitmap_offset<=0;
            bitmap_length<=0;
            diag_pub_valid<=0;diag_pub_length<=0;
            diag_pub_byte_offset<=0;diag_pub_page_field<=0;
        end else if(clear) begin
            section_count<=0;desc_type<=0;desc_offset<=0;
            desc_length<=0;desc_count<=0;desc_profile<=0;
            desc_record_bytes<=0;page_base<=0;page_end<=0;
            bitmap_base<=0;bitmap_end<=0;page_field<=0;
            pending_id<=0;pending_bitmap_offset<=0;
            pending_bitmap_length<=0;pending_profile<=0;
            pending_width<=0;pending_height<=0;pending_stride<=0;
            pending_notation<=0;pending_format<=0;
            page_found<=0;page_scan_complete<=0;
            page_id<=0;bitmap_offset<=0;
            selected_index<=0;valid_index<=0;first_valid<=0;
            first_id<=0;first_bitmap_offset<=0;
            bitmap_length<=0;
        end else if(scan_done && !page_found && first_valid) begin
            page_found<=1;
            page_id<=first_id;
            bitmap_offset<=first_bitmap_offset;
            bitmap_length<=32'd57600;
            selected_index<=0;
        end else if(byte_valid) begin
            if(byte_offset==32'd36) section_count[7:0]<=byte_data;
            if(byte_offset==32'd37) section_count[15:8]<=byte_data;
            if(in_descriptor) begin
                if(descriptor_field==0) begin
                    desc_type<=0;desc_offset<=0;desc_length<=0;
                    desc_count<=0;desc_profile<=0;desc_record_bytes<=0;
                end
                case(descriptor_field)
                    0,1,2,3:desc_type[8*descriptor_field +: 8]<=byte_data;
                    4,5:desc_profile[8*(descriptor_field-4) +: 8]<=byte_data;
                    8,9,10,11:desc_offset[8*(descriptor_field-8) +: 8]<=byte_data;
                    12,13,14,15:desc_length[8*(descriptor_field-12) +: 8]<=byte_data;
                    16,17,18,19:desc_count[8*(descriptor_field-16) +: 8]<=byte_data;
                    20,21:desc_record_bytes[8*(descriptor_field-20) +: 8]<=byte_data;
                    default:begin end
                endcase
                if(descriptor_field==31) begin
                    if(desc_type==32'd5 && desc_profile==16'd1 &&
                       desc_record_bytes==16'd24 && desc_count!=0 &&
                       desc_length==(desc_count<<4)+(desc_count<<3)) begin
                        page_base<=desc_offset;
                        page_end<=desc_offset+desc_length;
                    end
                    if(desc_type==32'd6 && desc_profile==16'd1 &&
                       desc_record_bytes==0 && desc_count==1) begin
                        bitmap_base<=desc_offset;
                        bitmap_end<=desc_offset+desc_length;
                    end
                end
            end else if(in_page && !page_found) begin
                if(byte_offset==page_end-32'd1)
                    page_scan_complete<=1;
                if(byte_offset==page_base) page_field<=1;
                else if(page_field==23) page_field<=0;
                else page_field<=page_field+1'b1;
                case(page_field)
                    0,1,2,3:pending_id[8*page_field +: 8]<=byte_data;
                    4,5:pending_profile[8*(page_field-4) +: 8]<=byte_data;
                    6:pending_notation<=byte_data;
                    7:pending_format<=byte_data;
                    8,9:pending_width[8*(page_field-8) +: 8]<=byte_data;
                    10,11:pending_height[8*(page_field-10) +: 8]<=byte_data;
                    12,13:pending_stride[8*(page_field-12) +: 8]<=byte_data;
                    16,17,18,19:pending_bitmap_offset
                        [8*(page_field-16) +: 8]<=byte_data;
                    20,21,22:pending_bitmap_length
                        [8*(page_field-20) +: 8]<=byte_data;
                    23:begin
                        if(pending_profile==16'd1 &&
                           pending_notation=={6'd0,notation} &&
                           pending_format==8'd1 &&
                           pending_width==16'd960 &&
                           pending_height==16'd480 &&
                           pending_stride==16'd120 &&
                           completed_length==32'd57600 &&
                           pending_bitmap_offset>=bitmap_base &&
                           bitmap_end>=32'd57600 &&
                           pending_bitmap_offset<=bitmap_end-32'd57600) begin
                            if(!first_valid) begin
                                first_valid<=1;
                                first_id<=pending_id;
                                first_bitmap_offset<=pending_bitmap_offset;
                            end
                            valid_index<=valid_index+1'b1;
                            if(valid_index==target_index) begin
                                page_found<=1;
                                page_id<=pending_id;
                                bitmap_offset<=pending_bitmap_offset;
                                selected_index<=valid_index;
                            // A published page has already passed the exact
                            // 57,600-byte check above. Do not carry the raw
                            // input byte into a second, contradictory length
                            // decision in the downstream reader.
                                bitmap_length<=32'd57600;
                            end
                            if(!diag_pub_valid) begin
                                diag_pub_valid<=1;
                                diag_pub_length<=completed_length;
                                diag_pub_byte_offset<=byte_offset;
                                diag_pub_page_field<=page_field;
                            end
                        end
                    end
                    default:begin end
                endcase
            end
        end
    end
endmodule
