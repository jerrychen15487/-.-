// Decode NOTE records from an already-validated PSC2 file byte stream.
// This module does not access the SD card or authenticate a file: the caller
// must only feed a committed package after its CRC/structure checks pass.
// byte_offset is the absolute position in the file; gaps are permitted.
module psc2_note_stream (
    input wire clk,
    input wire rst_n,
    input wire byte_valid,
    input wire [31:0] byte_offset,
    input wire [7:0] byte_data,
    output reg note_valid,
    output reg [31:0] note_index,
    output reg [31:0] start_tick,
    output reg [31:0] duration_tick,
    output reg [6:0] pitch,
    output reg [1:0] part_mask,
    output reg score_onset,
    output reg score_hold, score_velocity,
    output reg [2:0] dynamic,
    output reg descriptor_valid,
    output reg [31:0] total_notes,
    output reg [15:0] default_bpm
);
    reg [15:0] section_count;
    wire [31:0] descriptor_end = 32'd64 + ({16'd0,section_count} << 5);
    wire in_descriptor = byte_offset >= 32'd64 &&
        byte_offset < descriptor_end;
    wire [7:0] descriptor_field = (byte_offset - 32'd64) & 32'd31;
    reg [31:0] desc_type, desc_offset, desc_count;
    reg [15:0] desc_profile, desc_record_bytes;
    reg [31:0] note_base, note_end;
    reg [31:0] pending_start, pending_duration;
    reg [6:0] pending_pitch;
    reg [1:0] pending_part;
    reg [2:0] pending_score_flags,pending_dynamic;
    wire in_notes = descriptor_valid && byte_offset >= note_base &&
        byte_offset < note_end;
    wire [31:0] relative_offset = byte_offset - note_base;
    wire [3:0] record_field = relative_offset[3:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_valid <= 0; note_index <= 0;
            start_tick <= 0; duration_tick <= 0; pitch <= 0;
            part_mask <= 0; score_onset <= 0;
            score_hold<=0;score_velocity<=0;dynamic<=0;
            descriptor_valid <= 0; total_notes <= 0;
            default_bpm <= 0;
            desc_type <= 0; desc_offset <= 0; desc_count <= 0;
            desc_profile <= 0; desc_record_bytes <= 0;
            note_base <= 0; note_end <= 0;
            section_count <= 0;
            pending_start <= 0; pending_duration <= 0;
            pending_pitch <= 0; pending_part <= 0;
            pending_score_flags<=0;pending_dynamic<=0;
        end else begin
            note_valid <= 0;
            if (byte_valid) begin
                if (byte_offset == 0) begin
                    descriptor_valid <= 0;
                    total_notes <= 0;
                    section_count <= 0;
                    default_bpm <= 0;
                end
                if (byte_offset == 36) section_count[7:0] <= byte_data;
                if (byte_offset == 37) section_count[15:8] <= byte_data;
                if (byte_offset == 54) default_bpm[7:0] <= byte_data;
                if (byte_offset == 55) default_bpm[15:8] <= byte_data;
                if (in_descriptor) begin
                    if (descriptor_field == 0) begin
                        desc_type <= 0; desc_offset <= 0;
                        desc_count <= 0; desc_profile <= 0;
                        desc_record_bytes <= 0;
                    end
                    case (descriptor_field)
                        0,1,2,3: desc_type[8*descriptor_field +: 8] <= byte_data;
                        4,5: desc_profile[8*(descriptor_field-4) +: 8] <= byte_data;
                        8,9,10,11: desc_offset[8*(descriptor_field-8) +: 8] <= byte_data;
                        16,17,18,19: desc_count[8*(descriptor_field-16) +: 8] <= byte_data;
                        20,21: desc_record_bytes[8*(descriptor_field-20) +: 8] <= byte_data;
                        default: begin end
                    endcase
                    if (descriptor_field == 31 && desc_type == 32'd2 &&
                        desc_profile == 0 && desc_record_bytes == 16 &&
                        desc_count != 0 && desc_count <= 32'd8192 &&
                        desc_offset <= 32'hffff_ffff - (desc_count << 4)) begin
                        note_base <= desc_offset;
                        note_end <= desc_offset + (desc_count << 4);
                        total_notes <= desc_count;
                        descriptor_valid <= 1;
                    end
                end else if (in_notes) begin
                    case (record_field)
                        0,1,2,3: pending_start[8*record_field +: 8] <= byte_data;
                        4,5,6,7: pending_duration[8*(record_field-4) +: 8] <= byte_data;
                        8: pending_pitch <= byte_data[6:0];
                        9: pending_dynamic <= byte_data[2:0];
                        10: pending_part <= byte_data[1:0];
                        11: pending_score_flags <= byte_data[2:0];
                        15: begin
                            note_index <= relative_offset >> 4;
                            start_tick <= pending_start;
                            duration_tick <= pending_duration;
                            pitch <= pending_pitch;
                            part_mask <= pending_part;
                            score_onset <= pending_score_flags[0];
                            score_hold <= pending_score_flags[1];
                            score_velocity <= pending_score_flags[2];
                            dynamic <= pending_dynamic;
                            note_valid <= 1;
                        end
                        default: begin end
                    endcase
                end
            end
        end
    end
endmodule
