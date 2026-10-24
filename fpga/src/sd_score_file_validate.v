// Sequential PSC2 integrity/structure check for COMMIT. Every file byte and
// every section byte is CRC-checked before a directory item may become full.
// The transport metadata is trusted only as an expected value, not as proof.
module sd_score_file_validate (
    input wire clk,rst_n,start,
    input wire [2:0] slot,
    input wire [31:0] total_bytes,file_crc,capabilities,sector_count,
    input wire [127:0] uuid,
    input wire block_ready,block_done,
    input wire [7:0] block_error,
    output reg block_start,
    output wire [31:0] block_lba,
    output wire block_guard_valid,
    output wire [8:0] buffer_addr,
    input wire [7:0] buffer_rdata,
    output reg done,io_failed,bad_crc,bad_package
);
    localparam IDLE=0,REQUEST=1,WAIT_BLOCK=2,SCAN=3,
        CHECK_DESC=4,FINISH=5,SCAN_PREFETCH=6,CHECK_DESC_APPLY=7;
    reg [2:0] state;
    reg [2:0] held_slot;
    reg [31:0] held_total,held_crc,held_caps;
    reg [127:0] held_uuid;
    reg [11:0] sector_index;
    reg [8:0] byte_index;
    reg [7:0] scan_byte_q;
    reg [31:0] absolute_pos,running_crc,section_crc;
    reg [15:0] section_count,header_bytes,ppq,bpm;
    reg [31:0] header_total,header_caps,header_note_count;
    reg [127:0] header_uuid;
    reg [31:0] directory_offset;
    // The current PSC2 catalogue uses exactly the eight defined section
    // kinds. Advertise this limit in CAPS instead of implementing storage
    // and dynamic selection for 32 descriptors that the present renderer
    // cannot consume.
    reg [31:0] section_type[0:7];
    reg [15:0] section_profile[0:7],section_flags[0:7];
    reg [31:0] section_offset[0:7],section_length[0:7];
    reg [31:0] section_records[0:7],section_expected_crc[0:7];
    reg [15:0] section_record_bytes[0:7];
    reg [7:0] section_index,check_index;
    reg [7:0] seen_types;
    // Descriptor checks are performed only at COMMIT, not in the audio path.
    // Register independent predicate groups before updating status. This
    // prevents the indexed descriptor read and the full validity OR tree from
    // occupying the same 50 MHz clock period.
    reg check_bad_type_q,check_bad_range_q,check_bad_format_q,
        check_bad_records_q;
    reg check_known_type_q;
    reg [2:0] check_type_bit_q;
    reg header_ok,descriptors_ok;
    wire [31:0] next_lba;
    wire lba_valid;
    wire [31:0] descriptor_end=32'd64+({16'd0,section_count}<<5);
    wire [31:0] descriptor_start=absolute_pos-32'd64;
    wire [4:0] descriptor_field=descriptor_start[4:0];
    wire [4:0] descriptor_number=descriptor_start[9:5];
    wire [31:0] section_end=section_offset[section_index]+
        section_length[section_index];
    wire in_section=section_index<section_count &&
        absolute_pos>=section_offset[section_index] &&
        absolute_pos<section_end;
    assign buffer_addr=byte_index;
    assign block_lba=next_lba;
    assign block_guard_valid=lba_valid;
    sd_storage_lba address_guard (
        .region(2'd1),.directory_b(1'b0),.slot(held_slot),
        .index({1'b0,sector_index}),.sector_count(sector_count),
        .lba(next_lba),.valid(lba_valid)
    );
    function [31:0] crc_byte;
        input [31:0] prior;
        input [7:0] value;
        reg [31:0] c;
        integer i;
        begin
            c=prior^{24'd0,value};
            for(i=0;i<8;i=i+1)
                c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction
    function [15:0] fixed_record_size;
        input [31:0] kind;
        begin
            case(kind)
                2,4:fixed_record_size=16;
                3:fixed_record_size=8;
                5,7:fixed_record_size=24;
                8:fixed_record_size=4;
                default:fixed_record_size=0;
            endcase
        end
    endfunction
    // PSC2 fixed records have only power-of-two or 16+8 byte sizes.
    // A variable-width multiply here inferred a large DSP/combinational
    // network even though no general multiplier is needed.
    function [36:0] fixed_record_span;
        input [31:0] kind;
        input [31:0] count;
        reg [36:0] extended_count;
        begin
            extended_count={5'd0,count};
            case(kind)
                2,4:fixed_record_span=extended_count<<4;
                3:fixed_record_span=extended_count<<3;
                5,7:fixed_record_span=(extended_count<<4)+
                    (extended_count<<3);
                8:fixed_record_span=extended_count<<2;
                default:fixed_record_span=0;
            endcase
        end
    endfunction
    reg [31:0] prior_end;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; held_slot<=0; held_total<=0; held_crc<=0;
            held_caps<=0; held_uuid<=0; sector_index<=0;
            byte_index<=0; absolute_pos<=0; scan_byte_q<=0;
            running_crc<=32'hffffffff; section_crc<=32'hffffffff;
            section_count<=0; header_bytes<=0; ppq<=0; bpm<=0;
            header_total<=0; header_caps<=0; header_note_count<=0;
            header_uuid<=0; directory_offset<=0;
            section_index<=0; check_index<=0; seen_types<=0;
            check_bad_type_q<=0;check_bad_range_q<=0;
            check_bad_format_q<=0;check_bad_records_q<=0;
            check_known_type_q<=0;check_type_bit_q<=0;
            prior_end<=0; header_ok<=1; descriptors_ok<=1;
            block_start<=0; done<=0; io_failed<=0;
            bad_crc<=0; bad_package<=0;
        end else begin
            block_start<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    io_failed<=0; bad_crc<=0; bad_package<=0;
                    header_ok<=1; descriptors_ok<=1;
                    section_count<=0; header_bytes<=0; ppq<=0; bpm<=0;
                    header_total<=0; header_caps<=0; header_note_count<=0;
                    header_uuid<=0; directory_offset<=0;
                    section_index<=0; check_index<=0; seen_types<=0;
                    prior_end<=0; sector_index<=0; byte_index<=0;
                    absolute_pos<=0; running_crc<=32'hffffffff;
                    section_crc<=32'hffffffff;
                    held_slot<=slot; held_total<=total_bytes;
                    held_crc<=file_crc; held_caps<=capabilities;
                    held_uuid<=uuid;
                    if(slot>=6 || total_bytes==0 ||
                       total_bytes<32'd64 ||
                       total_bytes>32'd2097152 || uuid==0 ||
                       capabilities==0 ||
                       (capabilities & 32'hfffffff8)!=0) begin
                        bad_package<=1; state<=FINISH;
                    end else state<=REQUEST;
                end
                REQUEST: if(block_ready) begin
                    if(!lba_valid) begin io_failed<=1; state<=FINISH; end
                    else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin io_failed<=1; state<=FINISH; end
                    else begin byte_index<=0; state<=SCAN_PREFETCH; end
                end
                SCAN_PREFETCH: begin
                    scan_byte_q<=buffer_rdata;
                    state<=SCAN;
                end
                SCAN: begin
                    // CRC includes exactly total_bytes, not SD-sector padding.
                    running_crc<=crc_byte(running_crc,scan_byte_q);
                    if(absolute_pos<32'd64) begin
                        case(absolute_pos)
                            0:if(scan_byte_q!="P") header_ok<=0;
                            1:if(scan_byte_q!="S") header_ok<=0;
                            2:if(scan_byte_q!="C") header_ok<=0;
                            3:if(scan_byte_q!="2") header_ok<=0;
                            4:if(scan_byte_q!=2) header_ok<=0;
                            5,7,39:if(scan_byte_q!=0) header_ok<=0;
                            6:if(scan_byte_q!=0) header_ok<=0;
                            8,9,10,11:header_total[8*(absolute_pos-8) +: 8]<=scan_byte_q;
                            28,29,30,31:begin end // revision is opaque
                            36,37:section_count[8*(absolute_pos-36) +: 8]<=scan_byte_q;
                            38:header_bytes[7:0]<=scan_byte_q;
                            40,41,42,43:
                                directory_offset[8*(absolute_pos-40) +: 8]<=scan_byte_q;
                            44,45,46,47:
                                header_caps[8*(absolute_pos-44) +: 8]<=scan_byte_q;
                            48,49,50,51:
                                header_note_count[8*(absolute_pos-48) +: 8]<=scan_byte_q;
                            52,53:ppq[8*(absolute_pos-52) +: 8]<=scan_byte_q;
                            54,55:bpm[8*(absolute_pos-54) +: 8]<=scan_byte_q;
                            default:begin
                                if(absolute_pos>=12 && absolute_pos<28)
                                    header_uuid[127-8*(absolute_pos-12) -: 8]<=scan_byte_q;
                                if(absolute_pos>=56 && scan_byte_q!=0)
                                    header_ok<=0;
                            end
                        endcase
                    end else if(absolute_pos<descriptor_end &&
                                descriptor_number<8) begin
                        case(descriptor_field)
                            0,1,2,3:section_type[descriptor_number]
                                [8*descriptor_field +: 8]<=scan_byte_q;
                            4,5:section_profile[descriptor_number]
                                [8*(descriptor_field-4) +: 8]<=scan_byte_q;
                            6,7:section_flags[descriptor_number]
                                [8*(descriptor_field-6) +: 8]<=scan_byte_q;
                            8,9,10,11:section_offset[descriptor_number]
                                [8*(descriptor_field-8) +: 8]<=scan_byte_q;
                            12,13,14,15:section_length[descriptor_number]
                                [8*(descriptor_field-12) +: 8]<=scan_byte_q;
                            16,17,18,19:section_records[descriptor_number]
                                [8*(descriptor_field-16) +: 8]<=scan_byte_q;
                            20,21:section_record_bytes[descriptor_number]
                                [8*(descriptor_field-20) +: 8]<=scan_byte_q;
                            24,25,26,27:section_expected_crc[descriptor_number]
                                [8*(descriptor_field-24) +: 8]<=scan_byte_q;
                            default:if(scan_byte_q!=0) descriptors_ok<=0;
                        endcase
                    end else if(in_section) begin
                        section_crc<=crc_byte(section_crc,scan_byte_q);
                        if(absolute_pos+1'b1==section_end) begin
                            if(~crc_byte(section_crc,scan_byte_q)!=
                               section_expected_crc[section_index])
                                bad_crc<=1;
                            section_index<=section_index+1'b1;
                            section_crc<=32'hffffffff;
                        end
                    end else if(scan_byte_q!=0)
                        bad_package<=1; // gaps and file tail are zero-filled
                    if(absolute_pos==32'd63) begin
                        if(!header_ok || header_total!=held_total ||
                           header_uuid!=held_uuid ||
                           header_caps!=held_caps ||
                           header_bytes!=16'd64 ||
                           directory_offset!=32'd64 ||
                           section_count==0 || section_count>8 ||
                           header_note_count>32'd8192 ||
                           ppq!=16'd960 || bpm<20 || bpm>300 ||
                           descriptor_end>held_total)
                            bad_package<=1;
                    end
                    if(absolute_pos+1'b1==descriptor_end) begin
                        check_index<=0; prior_end<=descriptor_end;
                        state<=CHECK_DESC;
                    end else if(byte_index==9'd511) begin
                        if(absolute_pos+1'b1>=held_total) begin
                            if(~crc_byte(running_crc,scan_byte_q)!=held_crc)
                                bad_crc<=1;
                            if(section_index!=section_count &&
                               !(in_section && absolute_pos+1'b1==section_end &&
                                 section_index+1'b1==section_count))
                                bad_package<=1;
                            state<=FINISH;
                        end else begin
                            sector_index<=sector_index+1'b1;
                            absolute_pos<=absolute_pos+1'b1;
                            state<=REQUEST;
                        end
                    end else if(absolute_pos+1'b1==held_total) begin
                        if(~crc_byte(running_crc,scan_byte_q)!=held_crc)
                            bad_crc<=1;
                        if(section_index!=section_count &&
                           !(in_section && absolute_pos+1'b1==section_end &&
                             section_index+1'b1==section_count))
                            bad_package<=1;
                        state<=FINISH;
                    end else begin
                        byte_index<=byte_index+1'b1;
                        absolute_pos<=absolute_pos+1'b1;
                        state<=SCAN_PREFETCH;
                    end
                end
                CHECK_DESC: begin
                    if(check_index>=section_count) begin
                        if(!seen_types[0] ||
                           (held_caps[0] &&
                            (!seen_types[1] || !seen_types[3] ||
                             !seen_types[7] ||
                             ((held_caps[1] || held_caps[2]) &&
                              !seen_types[6]))) ||
                           ((held_caps[1] || held_caps[2]) &&
                            (!seen_types[4] || !seen_types[5])))
                            bad_package<=1;
                        // Continue at first byte after descriptor directory.
                        absolute_pos<=absolute_pos+1'b1;
                        if(byte_index==9'd511) begin
                            sector_index<=sector_index+1'b1;
                            state<=REQUEST;
                        end else begin
                            byte_index<=byte_index+1'b1;
                            state<=SCAN_PREFETCH;
                        end
                    end else begin
                        check_known_type_q<=section_type[check_index]>=1 &&
                            section_type[check_index]<=8;
                        check_type_bit_q<=section_type[check_index]-1'b1;
                        check_bad_type_q<=
                            (section_type[check_index]>=1 &&
                            section_type[check_index]<=8 &&
                            seen_types[section_type[check_index]-1'b1]) ||
                           (section_type[check_index]>=1 &&
                            section_type[check_index]<=8 &&
                            section_flags[check_index]!=1) ||
                           (section_type[check_index]>8 &&
                            section_flags[check_index]!=0) ||
                           section_type[check_index]==0;
                        check_bad_range_q<=
                           section_length[check_index]==0 ||
                           section_offset[check_index][1:0]!=0 ||
                           section_offset[check_index]<prior_end ||
                           section_offset[check_index]+
                             section_length[check_index]<
                             section_offset[check_index] ||
                           section_offset[check_index]+
                             section_length[check_index]>held_total;
                        check_bad_format_q<=
                           ((section_type[check_index]>=5 &&
                             section_type[check_index]<=7) &&
                             section_profile[check_index]!=1) ||
                           ((section_type[check_index]<5 ||
                             section_type[check_index]==8) &&
                             section_profile[check_index]!=0);
                        check_bad_records_q<=
                           (fixed_record_size(section_type[check_index])!=0 &&
                             (section_record_bytes[check_index]!=
                                fixed_record_size(section_type[check_index]) ||
                              {5'd0,section_length[check_index]}!=
                                fixed_record_span(section_type[check_index],
                                    section_records[check_index]))) ||
                           ((section_type[check_index]==1 ||
                             section_type[check_index]==6) &&
                             (section_record_bytes[check_index]!=0 ||
                              section_records[check_index]!=1)) ||
                           (section_type[check_index]==2 &&
                             section_records[check_index]!=header_note_count) ||
                           (section_type[check_index]==5 &&
                             section_records[check_index]>32);
                        state<=CHECK_DESC_APPLY;
                    end
                end
                CHECK_DESC_APPLY: begin
                        if(check_bad_type_q || check_bad_range_q ||
                           check_bad_format_q || check_bad_records_q)
                            bad_package<=1;
                        else if(check_known_type_q)
                            seen_types[check_type_bit_q]<=1;
                        prior_end<=section_offset[check_index]+
                            section_length[check_index];
                        check_index<=check_index+1'b1;
                        state<=CHECK_DESC;
                end
                FINISH: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
