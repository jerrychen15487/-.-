// Read the byte stream of one committed PSC2 slot and emit decoded NOTE
// records. This controller is read-only and must be arbitrated with the UART
// score store; it must never be started for a partial/unvalidated entry.
module sd_score_note_read #(
    parameter MAX_NOTES=20
) (
    input wire clk, rst_n, start,
    input wire [2:0] slot,
    input wire [31:0] total_bytes, sector_count,
    input wire block_ready, block_done,
    input wire [7:0] block_error, buffer_rdata,
    output reg block_start,
    output wire block_write,
    output wire [31:0] block_lba,
    output wire block_guard_valid,
    output wire [8:0] buffer_addr,
    output reg done, io_failed, invalid_spec,
    output wire note_valid, descriptor_valid,
    output wire [31:0] note_index, start_tick, duration_tick, total_notes,
    output wire [6:0] pitch,
    output wire [1:0] part_mask,
    output wire score_onset,
    output wire score_hold, score_velocity,
    output wire [2:0] dynamic,
    output wire [15:0] default_bpm
);
    localparam IDLE=0, REQUEST=1, WAIT_BLOCK=2, READ_BYTE=3,
        DRAIN=4, FINISH=5, DRAIN_PIPE=6;
    reg [2:0] state;
    reg [2:0] held_slot;
    reg [31:0] held_total, absolute_pos;
    reg [12:0] sector_index;
    reg [8:0] byte_index;
    reg [13:0] notes_seen;
    reg scan_valid_q;
    reg [31:0] scan_offset_q;
    reg [7:0] scan_data_q;
    wire [31:0] lba;
    wire lba_valid;
    assign block_write=1'b0;
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    assign buffer_addr=byte_index;
    sd_storage_lba address_guard(
        .region(2'd1),.directory_b(1'b0),.slot(held_slot),
        .index(sector_index),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
    psc2_note_stream decoder(
        .clk(clk),.rst_n(rst_n),.byte_valid(scan_valid_q),
        .byte_offset(scan_offset_q),.byte_data(scan_data_q),
        .note_valid(note_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .pitch(pitch),.part_mask(part_mask),
        .score_onset(score_onset),
        .score_hold(score_hold),.score_velocity(score_velocity),
        .dynamic(dynamic),
        .descriptor_valid(descriptor_valid),.total_notes(total_notes),
        .default_bpm(default_bpm)
    );
    wire note_section_done=descriptor_valid && total_notes!=0 &&
        (notes_seen>=total_notes ||
         (note_valid && note_index+1'b1>=total_notes));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; held_slot<=0; held_total<=0;
            absolute_pos<=0; sector_index<=0; byte_index<=0;
            notes_seen<=0;
            scan_valid_q<=0;scan_offset_q<=0;scan_data_q<=0;
            block_start<=0; done<=0; io_failed<=0; invalid_spec<=0;
        end else begin
            block_start<=0; done<=0;
            scan_valid_q<=0;
            // A record may finish while the next sector is being requested;
            // count decoder pulses independently of the byte-read state.
            if(note_valid) notes_seen<=notes_seen+1'b1;
            case(state)
                IDLE:if(start) begin
                    io_failed<=0; invalid_spec<=0;
                    if(slot>=6 || total_bytes<96 ||
                       total_bytes>32'd2097152) begin
                        invalid_spec<=1; state<=FINISH;
                    end else begin
                        held_slot<=slot; held_total<=total_bytes;
                        absolute_pos<=0; sector_index<=0;
                        byte_index<=0; notes_seen<=0; state<=REQUEST;
                    end
                end
                REQUEST:if(notes_seen>=MAX_NOTES || note_section_done)
                    state<=DRAIN;
                else if(block_ready) begin
                    if(!lba_valid) begin
                        io_failed<=1; state<=FINISH;
                    end else begin
                        block_start<=1; state<=WAIT_BLOCK;
                    end
                end
                WAIT_BLOCK:if(block_done) begin
                    if(block_error!=0) begin
                        io_failed<=1; state<=FINISH;
                    end else if(notes_seen>=MAX_NOTES || note_section_done)
                        state<=DRAIN;
                    else begin
                        byte_index<=0; state<=READ_BYTE;
                    end
                end
                READ_BYTE:begin
                    if(notes_seen>=MAX_NOTES || note_section_done ||
                       (note_valid && notes_seen+1'b1>=MAX_NOTES))
                        state<=DRAIN;
                    else begin
                        scan_valid_q<=1;
                        scan_offset_q<=absolute_pos;
                        scan_data_q<=buffer_rdata;
                        if(absolute_pos+1'b1==held_total) state<=DRAIN;
                        else begin
                            absolute_pos<=absolute_pos+1'b1;
                            if(byte_index==9'd511) begin
                                sector_index<=sector_index+1'b1;
                                state<=REQUEST;
                            end else byte_index<=byte_index+1'b1;
                        end
                    end
                end
                DRAIN:state<=DRAIN_PIPE;
                DRAIN_PIPE:state<=FINISH;
                FINISH:begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
