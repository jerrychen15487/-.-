// General PSC2 library transaction controller for the dedicated microSD card.
// UART ACK is emitted only after the underlying SD write/readback and, for
// catalog changes, the inactive directory copy has been re-mounted.
module score_store_v2 #(
    parameter MAX_SLOTS=6
) (
    input wire clk,rst_n,uart_rx,
    output wire uart_tx,
    input wire dev_ready,dev_init_done,dev_done,
    input wire [7:0] dev_error,dev_rdata,
    input wire [31:0] sector_count,
    output reg [8:0] dev_addr,
    output reg [7:0] dev_wdata,
    output reg dev_we,dev_start,dev_write,dev_guard,
    output reg [31:0] dev_lba,
    output wire storage_ready,
    output wire [31:0] catalog_generation,
    input wire preview_request,
    output reg preview_done, preview_available,
    output wire preview_note_valid,
    output wire [31:0] preview_note_index,
    output wire [31:0] preview_start_tick,
    output wire [31:0] preview_duration_tick,
    output wire [6:0] preview_pitch,
    output wire [1:0] preview_part_mask,
    output wire preview_score_onset,
    output wire preview_score_hold,preview_score_velocity,
    output wire [2:0] preview_dynamic,
    output wire [15:0] preview_bpm,
    input wire page_request,
    input wire [1:0] page_notation,
    input wire [5:0] page_index,
    input wire [15:0] page_request_token,
    output reg page_begin,page_done,page_available,
    output reg [5:0] page_selected_index,
    output reg [15:0] page_completed_token,
    // 0=pending, 3=no committed slot/card, 4=SD I/O,
    // 5=short file, 6=notation page absent, 7=page available,
    // 8=reader input rejected, 9=offset past EOF, 10=length mismatch,
    // 11=bitmap crosses EOF, 12=catalog length itself is short.
    // Valid with page_done.
    output reg [3:0] page_result,
    output wire page_byte_valid,
    output wire [15:0] page_byte_index,
    output wire [7:0] page_byte,
    output wire page_diag_err_valid,page_diag_err_page_found,
        page_diag_err_index_clear,page_diag_pub_valid,
    output wire [2:0] page_diag_err_state,
    output wire [31:0] page_diag_err_length,page_diag_err_offset,
        page_diag_err_total,page_diag_pub_length,
        page_diag_pub_byte_offset,
    output wire [4:0] page_diag_pub_page_field
);
    localparam O_NONE=0,O_MOUNT=1,O_IMAGE=2,O_COPY=3,
        O_WRITE=4,O_SCAN=5,O_VALIDATE=6,O_DUP=7,O_NOTE=8,
        O_PAGE=9;
    localparam S_BOOT=0,S_MOUNT_LAUNCH=1,S_MOUNT_WAIT=2,
        S_IMAGE_LAUNCH=3,S_IMAGE_WAIT=4,S_PARSE=5,S_PARSE_CHECK=6,
        S_RECOVER=7,S_RECOVER_WAIT=8,S_READY=9,S_LOAD=10,
        S_HANDLE=11,S_MUTATE=12,S_PUBLISH_LAUNCH=13,
        S_PUBLISH_WAIT=14,S_CONFIRM_LAUNCH=15,S_CONFIRM_WAIT=16,
        S_WRITE_LAUNCH=17,S_WRITE_WAIT=18,S_VALIDATE_LAUNCH=19,
        S_VALIDATE_WAIT=20,S_DUP_LAUNCH=21,S_DUP_WAIT=22,
        S_DUP_COMPARE=23,S_RESPOND=24,S_REPLY_WAIT=25,
        S_LOOKUP=26,S_PARSE_PREFETCH=27,S_NOTE_WAIT=28,
        S_DUP_PREFETCH=29,S_LOAD_PREFETCH=30,
        S_LOAD_READ=31,S_DUP_READ=32,S_MUTATE_READ=33,
        S_DATA_PREP_INDEX=34,S_DATA_PREP_BYTES=35,
        S_PAGE_WAIT=36;
    localparam R_CAPS=0,R_STATUS=1,R_LIST=2,R_PROGRESS=3,
        R_COMMIT=4,R_DELETE=5,R_ERROR=6;
    localparam M_BEGIN=0,M_COMMIT=1,M_DELETE=2;
    reg [5:0] state;
    reg [3:0] owner;
    reg [127:0] entry_uuid[0:MAX_SLOTS-1];
    reg [7:0] entry_state[0:MAX_SLOTS-1];
    reg [15:0] entry_title_len[0:MAX_SLOTS-1];
    reg [31:0] entry_total[0:MAX_SLOTS-1],
        entry_crc[0:MAX_SLOTS-1],entry_caps[0:MAX_SLOTS-1],
        entry_blocks[0:MAX_SLOTS-1],entry_next[0:MAX_SLOTS-1];
    reg [63:0] entry_epoch[0:MAX_SLOTS-1];
    reg [8:0] compare_pos;
    reg [7:0] dup_request_byte_q;
    reg [7:0] dup_device_byte_q;
    reg [7:0] load_request_byte_q;
    reg mount_start,image_start,copy_start,write_start,scan_start,
        validate_start,dup_start;
    reg [8:0] dup_addr;
    wire mount_block_start,mount_guard,mount_done,mounted,mount_io_error,
        mount_blank,mount_a_valid,mount_b_valid;
    wire [31:0] mount_lba,mount_generation,mount_a_gen,mount_b_gen;
    wire [2:0] mount_count,mount_a_count,mount_b_count;
    wire [8:0] mount_addr;
    sd_directory_mount #(.MAX_ENTRIES(MAX_SLOTS)) mount (
        .clk(clk),.rst_n(rst_n),.start(mount_start),
        .block_ready(dev_ready && owner==O_MOUNT),
        .block_done(dev_done && owner==O_MOUNT),
        .block_error(dev_error),.sector_count(sector_count),
        .block_start(mount_block_start),.block_lba(mount_lba),
        .block_guard_valid(mount_guard),.buffer_addr(mount_addr),
        .buffer_rdata(dev_rdata),.done(mount_done),.mounted(mounted),
        .io_error(mount_io_error),.blank_media(mount_blank),
        .generation(mount_generation),.entry_count(mount_count),
        .a_valid(mount_a_valid),.b_valid(mount_b_valid),
        .a_generation(mount_a_gen),.b_generation(mount_b_gen),
        .a_entry_count(mount_a_count),.b_entry_count(mount_b_count)
    );
    reg active_copy_b;
    reg [31:0] generation;
    reg [2:0] highwater;
    assign catalog_generation=generation;
    reg card_fault;
    assign storage_ready=state==S_READY && !card_fault;
    wire image_block_start,image_guard,image_done,image_failed;
    wire [31:0] image_lba;
    wire [8:0] image_addr;
    reg [11:0] image_read_addr,image_write_addr;
    reg [7:0] image_write_byte;
    reg image_we;
    wire [7:0] image_byte;
    sd_directory_image image (
        .clk(clk),.rst_n(rst_n),.start(image_start),
        .directory_b(active_copy_b),.sector_count(sector_count),
        .block_ready(dev_ready && owner==O_IMAGE),
        .block_done(dev_done && owner==O_IMAGE),
        .block_error(dev_error),.block_start(image_block_start),
        .block_lba(image_lba),.block_guard_valid(image_guard),
        .buffer_addr(image_addr),.buffer_rdata(dev_rdata),
        .read_addr(image_read_addr),.read_byte(image_byte),
        .write_enable(image_we),.write_addr(image_write_addr),
        .write_byte(image_write_byte),.done(image_done),
        .io_failed(image_failed)
    );
    wire copy_block_start,copy_guard,copy_we,copy_done,copy_failed;
    wire [31:0] copy_lba;
    wire [8:0] copy_addr;
    wire [7:0] copy_wdata;
    wire [11:0] copy_source_addr;
    reg [31:0] pending_generation;
    reg [2:0] pending_highwater;
    sd_directory_copy_write #(.MAX_ENTRIES(MAX_SLOTS)) copy_writer (
        .clk(clk),.rst_n(rst_n),.start(copy_start),
        .target_b(!active_copy_b),.new_generation(pending_generation),
        .new_entry_count(pending_highwater),
        .sector_count(sector_count),.source_addr(copy_source_addr),
        .source_byte(image_byte),
        .block_ready(dev_ready && owner==O_COPY),
        .block_done(dev_done && owner==O_COPY),
        .block_error(dev_error),.block_start(copy_block_start),
        .block_lba(copy_lba),.block_guard_valid(copy_guard),
        .buffer_we(copy_we),.buffer_addr(copy_addr),
        .buffer_wdata(copy_wdata),.done(copy_done),.failed(copy_failed)
    );
    reg [2:0] work_slot;
    wire write_block_start,write_block_write,write_guard,write_we,
        write_done,write_failed;
    wire [31:0] write_lba;
    wire [8:0] write_addr,write_stage_addr;
    wire [7:0] write_wdata;
    reg [9:0] data_bytes;
    reg [11:0] data_index;
    wire [9:0] request_addr;
    wire [7:0] request_byte;
    sd_score_block_write data_writer (
        .clk(clk),.rst_n(rst_n),.start(write_start),
        .slot(work_slot),.block_index(data_index),
        .valid_bytes(data_bytes),.uuid(entry_uuid[work_slot]),
        .slot_epoch(entry_epoch[work_slot]),
        .sector_count(sector_count),.stage_addr(write_stage_addr),
        .stage_byte(request_byte),
        .block_ready(dev_ready && owner==O_WRITE),
        .block_done(dev_done && owner==O_WRITE),
        .block_error(dev_error),.block_start(write_block_start),
        .block_write(write_block_write),.block_lba(write_lba),
        .block_guard_valid(write_guard),.buffer_we(write_we),
        .buffer_addr(write_addr),.buffer_wdata(write_wdata),
        .done(write_done),.failed(write_failed)
    );
    wire scan_block_start,scan_block_write,scan_guard,scan_done,
        scan_io_failed,scan_bad_spec;
    wire [31:0] scan_lba;
    wire [8:0] scan_addr;
    wire [12:0] scan_next;
    sd_score_progress_scan progress_scanner (
        .clk(clk),.rst_n(rst_n),.start(scan_start),
        .slot(work_slot),.total_bytes(entry_total[work_slot]),
        .uuid(entry_uuid[work_slot]),
        .slot_epoch(entry_epoch[work_slot]),
        .sector_count(sector_count),
        .block_ready(dev_ready && owner==O_SCAN),
        .block_done(dev_done && owner==O_SCAN),
        .block_error(dev_error),.block_start(scan_block_start),
        .block_write(scan_block_write),.block_lba(scan_lba),
        .block_guard_valid(scan_guard),.buffer_addr(scan_addr),
        .buffer_rdata(dev_rdata),.done(scan_done),
        .io_failed(scan_io_failed),.invalid_spec(scan_bad_spec),
        .next_block(scan_next)
    );
    wire validate_block_start,validate_guard,validate_done,
        validate_io_failed,validate_bad_crc,validate_bad_package;
    wire [31:0] validate_lba;
    wire [8:0] validate_addr;
    sd_score_file_validate file_validator (
        .clk(clk),.rst_n(rst_n),.start(validate_start),
        .slot(work_slot),.total_bytes(entry_total[work_slot]),
        .file_crc(entry_crc[work_slot]),
        .capabilities(entry_caps[work_slot]),
        .sector_count(sector_count),.uuid(entry_uuid[work_slot]),
        .block_ready(dev_ready && owner==O_VALIDATE),
        .block_done(dev_done && owner==O_VALIDATE),
        .block_error(dev_error),.block_start(validate_block_start),
        .block_lba(validate_lba),.block_guard_valid(validate_guard),
        .buffer_addr(validate_addr),.buffer_rdata(dev_rdata),
        .done(validate_done),.io_failed(validate_io_failed),
        .bad_crc(validate_bad_crc),.bad_package(validate_bad_package)
    );
    reg preview_pending, preview_start;
    wire preview_read_done, preview_read_io_failed, preview_bad_spec;
    wire preview_block_start, preview_guard;
    wire [31:0] preview_lba;
    wire [8:0] preview_addr;
    wire preview_descriptor_valid;
    wire [31:0] preview_total_notes;
    sd_score_note_read #(.MAX_NOTES(8192)) note_reader (
        .clk(clk),.rst_n(rst_n),.start(preview_start),
        .slot(work_slot),.total_bytes(entry_total[work_slot]),
        .sector_count(sector_count),
        .block_ready(dev_ready && owner==O_NOTE),
        .block_done(dev_done && owner==O_NOTE),
        .block_error(dev_error),.buffer_rdata(dev_rdata),
        .block_start(preview_block_start),.block_write(),
        .block_lba(preview_lba),.block_guard_valid(preview_guard),
        .buffer_addr(preview_addr),.done(preview_read_done),
        .io_failed(preview_read_io_failed),.invalid_spec(preview_bad_spec),
        .note_valid(preview_note_valid),
        .descriptor_valid(preview_descriptor_valid),
        .note_index(preview_note_index),
        .start_tick(preview_start_tick),
        .duration_tick(preview_duration_tick),
        .pitch(preview_pitch),.part_mask(preview_part_mask),
        .score_onset(preview_score_onset),
        .score_hold(preview_score_hold),
        .score_velocity(preview_score_velocity),
        .dynamic(preview_dynamic),
        .total_notes(preview_total_notes),.default_bpm(preview_bpm)
    );
    reg page_pending,page_start;
    reg [1:0] page_notation_pending;
    reg [5:0] page_index_pending;
    reg [15:0] page_token_pending,page_token_active;
    wire [5:0] page_read_selected_index;
    wire page_read_done,page_read_found,page_read_io_failed,page_bad_spec,
        page_bad_input;
    wire [2:0] page_invalid_reason;
    wire page_block_start,page_guard;
    wire [31:0] page_lba;
    wire [8:0] page_addr;
    sd_score_page_read page_reader (
        .clk(clk),.rst_n(rst_n),.start(page_start),
        .slot(3'd0),.notation(page_notation_pending),
        .page_index(page_index_pending),
        .total_bytes(entry_total[0]),.sector_count(sector_count),
        .block_ready(dev_ready && owner==O_PAGE),
        .block_done(dev_done && owner==O_PAGE),
        .block_error(dev_error),.buffer_rdata(dev_rdata),
        .block_start(page_block_start),.block_write(),
        .block_lba(page_lba),.block_guard_valid(page_guard),
        .buffer_addr(page_addr),.bitmap_byte_valid(page_byte_valid),
        .bitmap_byte_index(page_byte_index),.bitmap_byte(page_byte),
        .done(page_read_done),.found(page_read_found),
        .selected_page_index(page_read_selected_index),
        .io_failed(page_read_io_failed),.invalid_spec(page_bad_spec),
        .invalid_input(page_bad_input),
        .invalid_reason(page_invalid_reason),
        .diag_err_valid(page_diag_err_valid),
        .diag_err_page_found(page_diag_err_page_found),
        .diag_err_index_clear(page_diag_err_index_clear),
        .diag_err_state(page_diag_err_state),
        .diag_err_length(page_diag_err_length),
        .diag_err_offset(page_diag_err_offset),
        .diag_err_total(page_diag_err_total),
        .diag_pub_valid(page_diag_pub_valid),
        .diag_pub_length(page_diag_pub_length),
        .diag_pub_byte_offset(page_diag_pub_byte_offset),
        .diag_pub_page_field(page_diag_pub_page_field)
    );
    wire [31:0] dup_lba;
    wire dup_guard;
    sd_storage_lba duplicate_address (
        .region(2'd1),.directory_b(1'b0),.slot(work_slot),
        .index({1'b0,data_index}),.sector_count(sector_count),
        .lba(dup_lba),.valid(dup_guard)
    );
    reg selected_start,selected_write,selected_guard;
    reg [31:0] selected_lba;
    // Register each SD request at the shared-device boundary. The selected
    // block controller remains in WAIT_BLOCK, so a one-clock launch delay is
    // harmless and removes the long LBA/guard mux from the device FSM path.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            dev_start<=0;dev_write<=0;dev_guard<=0;dev_lba<=0;
        end else begin
            dev_start<=selected_start;
            if(selected_start) begin
                dev_write<=selected_write;
                dev_guard<=selected_guard;
                dev_lba<=selected_lba;
            end
        end
    end
    wire [8:0] dup_read_addr =
        (state==S_DUP_COMPARE || state==S_DUP_PREFETCH) ?
        compare_pos : dup_addr;
    always @* begin
        dev_addr=0;dev_wdata=0;dev_we=0;selected_start=0;
        selected_write=0;selected_guard=0;selected_lba=0;
        case(owner)
            O_MOUNT:begin
                dev_addr=mount_addr;
                selected_start=mount_block_start;
                selected_guard=mount_guard;selected_lba=mount_lba;
            end
            O_IMAGE:begin
                dev_addr=image_addr;
                selected_start=image_block_start;
                selected_guard=image_guard;selected_lba=image_lba;
            end
            O_COPY:begin
                dev_addr=copy_addr;
                dev_wdata=copy_wdata;
                dev_we=copy_we;selected_start=copy_block_start;
                selected_write=1;selected_guard=copy_guard;
                selected_lba=copy_lba;
            end
            O_WRITE:begin
                dev_addr=write_addr;
                dev_wdata=write_wdata;
                dev_we=write_we;selected_start=write_block_start;
                selected_write=write_block_write;
                selected_guard=write_guard;selected_lba=write_lba;
            end
            O_SCAN:begin
                dev_addr=scan_addr;
                selected_start=scan_block_start;
                selected_guard=scan_guard;selected_lba=scan_lba;
            end
            O_VALIDATE:begin
                dev_addr=validate_addr;
                selected_start=validate_block_start;
                selected_guard=validate_guard;selected_lba=validate_lba;
            end
            O_DUP:begin
                dev_addr=dup_read_addr;
                selected_start=dup_start;
                selected_guard=dup_guard;selected_lba=dup_lba;
            end
            O_NOTE:begin
                dev_addr=preview_addr;
                selected_start=preview_block_start;
                selected_guard=preview_guard;
                selected_lba=preview_lba;
            end
            O_PAGE:begin
                dev_addr=page_addr;
                selected_start=page_block_start;
                selected_guard=page_guard;
                selected_lba=page_lba;
            end
            default:begin end
        endcase
    end
    wire request_valid,crc_error_pulse,reply_addr_done;
    wire [7:0] request_type;
    wire [31:0] request_session,request_seq;
    wire [10:0] request_len;
    reg reply_valid;
    reg [7:0] reply_type;
    reg [10:0] reply_len;
    wire [9:0] reply_addr;
    reg [7:0] reply_byte;
    score_uart_v2_transport transport (
        .clk(clk),.rst_n(rst_n),.rx(uart_rx),.tx(uart_tx),
        .request_valid(request_valid),
        .crc_error_pulse(crc_error_pulse),
        .request_type(request_type),
        .request_session(request_session),.request_seq(request_seq),
        .request_len(request_len),.request_addr(request_addr),
        .request_byte(request_byte),.reply_valid(reply_valid),
        .reply_type(reply_type),.reply_len(reply_len),
        .reply_addr(reply_addr),.reply_byte(reply_byte),
        .reply_done(reply_addr_done)
    );
    reg [2:0] parse_slot,recover_slot,active_slot;
    reg active_valid;
    reg [8:0] parse_pos,mutate_pos;
    // Keep the title payload address one cycle ahead of directory mutation.
    // Otherwise mutate_pos -> address arithmetic -> async payload RAM ->
    // controller state is a single long 50 MHz path.
    reg [9:0] mutate_title_addr;
    reg [1:0] mutation;
    reg [2:0] pending_slot;
    reg [10:0] load_pos,held_req_len;
    reg [7:0] held_req_type;
    reg [31:0] held_session,held_seq,req_hash;
    reg [127:0] req_uuid;
    reg [31:0] req_total,req_crc,req_blocks,req_caps,
        req_block_index,req_generation,req_cursor;
    reg [15:0] req_block_bytes,req_major,req_title_len,req_limit,
        req_reserved;
    reg [7:0] utf8_need,utf8_lead,scalar_count;
    reg utf8_first;
    reg title_bad;
    reg [2:0] reply_mode;
    reg [15:0] error_code;
    reg [31:0] error_next;
    reg [2:0] reply_slot,list_slot;
    reg list_found,deleted_flag;
    reg [31:0] list_next;
    reg [31:0] previous_session,previous_seq,previous_hash;
    reg [10:0] previous_len;
    reg [7:0] previous_type;
    reg [2:0] previous_reply_mode;
    reg [7:0] previous_reply_type;
    reg [10:0] previous_reply_len;
    reg [15:0] previous_error_code;
    reg [31:0] previous_error_next;
    reg previous_valid;
    integer i,j;
    reg match_found,free_found;
    reg [2:0] match_slot,free_slot;
    reg [2:0] list_candidate;
    reg list_candidate_found;
    reg [2:0] lookup_slot;
    function [7:0] le32;
        input [31:0] value;
        input [1:0] part;
        begin le32=value[8*part +: 8]; end
    endfunction
    function [7:0] le16;
        input [15:0] value;
        input part;
        begin le16=value[8*part +: 8]; end
    endfunction
    function [31:0] crc_byte;
        input [31:0] prior;
        input [7:0] value;
        reg [31:0] c;
        integer k;
        begin
            c=prior^{24'd0,value};
            for(k=0;k<8;k=k+1)
                c=c[0] ? ((c>>1)^32'hedb88320):(c>>1);
            crc_byte=c;
        end
    endfunction
    reg later_found;
    reg [31:0] later_cursor;
    assign request_addr=(state==S_LOAD || state==S_LOAD_PREFETCH ||
                         state==S_LOAD_READ)
        ? load_pos[9:0] :
        ((state==S_MUTATE || state==S_MUTATE_READ) &&
         mutation==M_BEGIN && mutate_pos>=48)
            ? mutate_title_addr :
        (owner==O_WRITE) ? (10'd20+write_stage_addr) :
        (owner==O_DUP) ? (10'd20+
            ((state==S_DUP_COMPARE || state==S_DUP_PREFETCH ||
              state==S_DUP_READ)
                ? compare_pos : dup_addr)) : 10'd0;
    always @* begin
        image_read_addr=0;
        if(owner==O_COPY) image_read_addr=copy_source_addr;
        else if(state==S_PARSE || state==S_PARSE_PREFETCH)
            image_read_addr=12'd16+parse_slot*12'd448+parse_pos;
        else if(reply_mode==R_LIST && list_found &&
                reply_addr>=10'd60)
            image_read_addr=12'd16+list_slot*12'd448+12'd48+
                (reply_addr-10'd60);
    end
    reg [7:0] new_entry_byte;
    always @* begin
        new_entry_byte=0;
        if(mutation==M_BEGIN) begin
            if(mutate_pos<16)
                new_entry_byte=req_uuid[127-8*mutate_pos -: 8];
            else case(mutate_pos)
                16:new_entry_byte=1;
                18,19:new_entry_byte=le16(req_title_len,mutate_pos-18);
                20,21,22,23:new_entry_byte=le32(req_total,mutate_pos-20);
                24,25,26,27:new_entry_byte=le32(req_crc,mutate_pos-24);
                28,29,30,31:new_entry_byte=le32(req_caps,mutate_pos-28);
                32,33,34,35:new_entry_byte=le32(req_blocks,mutate_pos-32);
                36:new_entry_byte=0;
                37:new_entry_byte=2;
                38:new_entry_byte=2;
                40,41,42,43:new_entry_byte=
                    le32(pending_generation,mutate_pos-40);
                44,45,46,47:new_entry_byte=
                    le32({29'd0,pending_slot}+32'd1,mutate_pos-44);
                default:if(mutate_pos>=48 &&
                           mutate_pos-48<req_title_len)
                    new_entry_byte=request_byte;
            endcase
        end else if(mutation==M_COMMIT && mutate_pos==16)
            new_entry_byte=2;
    end
    always @* begin
        image_we=(state==S_MUTATE);
        image_write_addr=12'd16+pending_slot*12'd448+mutate_pos;
        image_write_byte=new_entry_byte;
    end
    wire [31:0] reply_progress_saved=
        (entry_next[reply_slot]>=entry_blocks[reply_slot]) ?
        entry_total[reply_slot] : (entry_next[reply_slot]<<9);
    reg [31:0] free_slots;
    integer k;
    always @* begin
        free_slots=0;
        for(k=0;k<MAX_SLOTS;k=k+1)
            if(entry_state[k]==0) free_slots=free_slots+1'b1;
    end
    reg [7:0] list_item_byte;
    always @* begin
        list_item_byte=0;
        if(list_found) begin
            if(reply_addr>=16 && reply_addr<32)
                list_item_byte=entry_uuid[list_slot]
                    [127-8*(reply_addr-16) -: 8];
            else if(reply_addr==32) list_item_byte=entry_state[list_slot];
            else if(reply_addr>=36 && reply_addr<40)
                list_item_byte=le32(entry_total[list_slot],reply_addr-36);
            else if(reply_addr>=40 && reply_addr<44)
                list_item_byte=le32(entry_crc[list_slot],reply_addr-40);
            else if(reply_addr>=44 && reply_addr<48)
                list_item_byte=le32(entry_caps[list_slot],reply_addr-44);
            else if(reply_addr>=48 && reply_addr<52)
                list_item_byte=le32(entry_state[list_slot]==2 ?
                    entry_blocks[list_slot]:entry_next[list_slot],
                    reply_addr-48);
            else if(reply_addr>=52 && reply_addr<56)
                list_item_byte=le32(entry_blocks[list_slot],reply_addr-52);
            else if(reply_addr>=56 && reply_addr<58)
                list_item_byte=le16(entry_title_len[list_slot],
                    reply_addr-56);
            else if(reply_addr>=60) list_item_byte=image_byte;
        end
    end
    always @* begin
        reply_byte=0;
        if(reply_mode==R_ERROR) begin
            case(reply_addr)
                0:reply_byte=held_req_type;
                2,3:reply_byte=le16(error_code,reply_addr-2);
                4,5,6,7:reply_byte=le32(error_next,reply_addr-4);
                default:reply_byte=0;
            endcase
        end else if(reply_addr==0) reply_byte=held_req_type;
        else if(reply_addr>=4) case(reply_mode)
            R_CAPS:case(reply_addr)
                4:reply_byte=2;6:reply_byte=2;
                9:reply_byte=4;11:reply_byte=2;
                14:reply_byte=8'h20;
                17:reply_byte=8'h20;
                20:reply_byte=MAX_SLOTS;24:reply_byte=MAX_SLOTS;
                28:reply_byte=8;32:reply_byte=32;
                36:reply_byte=1;38:reply_byte=1;
                40:reply_byte=1;
                default:reply_byte=0;
            endcase
            R_STATUS:begin
                if(reply_addr==5) reply_byte=active_valid ? 1:0;
                else if(reply_addr>=8 && reply_addr<12)
                    reply_byte=le32(generation,reply_addr-8);
                else if(reply_addr>=12 && reply_addr<16)
                    reply_byte=le32(free_slots<<21,reply_addr-12);
                else if(reply_addr>=20 && reply_addr<36 && active_valid)
                    reply_byte=entry_uuid[active_slot]
                        [127-8*(reply_addr-20) -: 8];
                else if(reply_addr>=36 && reply_addr<40 && active_valid)
                    reply_byte=le32(entry_next[active_slot],reply_addr-36);
                else if(reply_addr>=40 && reply_addr<44 && active_valid)
                    reply_byte=le32(entry_blocks[active_slot],reply_addr-40);
            end
            R_LIST:begin
                if(reply_addr>=4 && reply_addr<8)
                    reply_byte=le32(generation,reply_addr-4);
                else if(reply_addr>=8 && reply_addr<12)
                    reply_byte=le32(list_next,reply_addr-8);
                else if(reply_addr==12) reply_byte=list_found ? 1:0;
                else reply_byte=list_item_byte;
            end
            R_PROGRESS:begin
                if(reply_addr>=4 && reply_addr<20)
                    reply_byte=entry_uuid[reply_slot]
                        [127-8*(reply_addr-4) -: 8];
                else if(reply_addr>=20 && reply_addr<24)
                    reply_byte=le32(entry_next[reply_slot],reply_addr-20);
                else if(reply_addr>=24 && reply_addr<28)
                    reply_byte=le32(entry_blocks[reply_slot],reply_addr-24);
                else if(reply_addr>=28 && reply_addr<32)
                    reply_byte=le32(reply_progress_saved,reply_addr-28);
            end
            R_COMMIT:begin
                if(reply_addr>=4 && reply_addr<20)
                    reply_byte=entry_uuid[reply_slot]
                        [127-8*(reply_addr-4) -: 8];
                else if(reply_addr>=20 && reply_addr<24)
                    reply_byte=le32(entry_crc[reply_slot],reply_addr-20);
                else if(reply_addr==24) reply_byte=2;
            end
            R_DELETE:begin
                if(reply_addr>=4 && reply_addr<20)
                    reply_byte=req_uuid[127-8*(reply_addr-4) -: 8];
                else if(reply_addr==20) reply_byte=deleted_flag;
            end
            default:reply_byte=0;
        endcase
    end
    reg [26:0] boot_ticks;
    reg queued_valid;
    reg [7:0] queued_type;
    reg [31:0] queued_session,queued_seq;
    reg [10:0] queued_len;
    reg replay_response;
    reg reject_response;
    // A DATA request's block-index check, last-block calculation and length
    // validation used to form one 50 MHz path into data_bytes.CE. The lookup
    // already takes several clocks, so spend two more clocks registering the
    // exact same 32-bit result before S_HANDLE uses it.
    reg data_block_in_range, data_block_last;
    reg [31:0] expected_data_bytes;
    task success_response;
        input [2:0] mode;
        input [10:0] length;
        begin
            reply_mode<=mode;
            reply_type<=8'h80;
            reply_len<=length;
            state<=S_RESPOND;
        end
    endtask
    task error_response;
        input [15:0] code;
        input [31:0] next_block;
        begin
            reply_mode<=R_ERROR;
            reply_type<=8'hff;
            reply_len<=11'd8;
            error_code<=code;
            error_next<=next_block;
            state<=S_RESPOND;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=S_BOOT;owner<=O_NONE;card_fault<=0;
            active_copy_b<=0;generation<=0;highwater<=0;
            mount_start<=0;image_start<=0;copy_start<=0;
            write_start<=0;scan_start<=0;validate_start<=0;
            dup_start<=0;dup_addr<=0;
            work_slot<=0;data_bytes<=0;data_index<=0;
            parse_slot<=0;parse_pos<=0;recover_slot<=0;
            active_slot<=0;active_valid<=0;
            mutate_pos<=0;mutate_title_addr<=10'd40;
            mutation<=M_BEGIN;pending_slot<=0;
            pending_generation<=0;pending_highwater<=0;
            load_pos<=0;held_req_len<=0;held_req_type<=0;
            held_session<=0;held_seq<=0;req_hash<=0;
            req_uuid<=0;req_total<=0;req_crc<=0;req_blocks<=0;
            req_caps<=0;req_block_index<=0;req_generation<=0;
            req_cursor<=0;req_block_bytes<=0;req_major<=0;
            req_title_len<=0;req_limit<=0;req_reserved<=0;
            utf8_need<=0;utf8_lead<=0;scalar_count<=0;
            utf8_first<=0;title_bad<=0;
            reply_valid<=0;reply_type<=0;reply_len<=0;
            reply_mode<=R_ERROR;error_code<=0;
            error_next<=32'hffffffff;reply_slot<=0;
            list_slot<=0;list_found<=0;list_next<=32'hffffffff;
            deleted_flag<=0;previous_session<=0;previous_seq<=0;
            previous_hash<=0;previous_len<=0;previous_type<=0;
            previous_valid<=0;replay_response<=0;
            reject_response<=0;
            previous_reply_mode<=0;previous_reply_type<=0;
            previous_reply_len<=0;previous_error_code<=0;
            previous_error_next<=0;
            compare_pos<=0;dup_request_byte_q<=0;
            dup_device_byte_q<=0;
            load_request_byte_q<=0;boot_ticks<=0;
            match_found<=0;free_found<=0;
            match_slot<=0;free_slot<=0;lookup_slot<=0;
            list_candidate<=0;list_candidate_found<=0;
            later_found<=0;later_cursor<=32'hffffffff;
            queued_valid<=0;queued_type<=0;
            queued_session<=0;queued_seq<=0;queued_len<=0;
            data_block_in_range<=0;data_block_last<=0;
            expected_data_bytes<=0;
            preview_pending<=0;preview_start<=0;
            preview_done<=0;preview_available<=0;
            page_pending<=0;page_start<=0;page_begin<=0;
            page_done<=0;page_available<=0;page_result<=0;
            page_notation_pending<=0;
            page_index_pending<=0;page_selected_index<=0;
            page_token_pending<=0;page_token_active<=0;
            page_completed_token<=0;
            for(i=0;i<MAX_SLOTS;i=i+1) begin
                entry_uuid[i]<=0;entry_state[i]<=0;
                entry_title_len[i]<=0;entry_total[i]<=0;
                entry_crc[i]<=0;entry_caps[i]<=0;
                entry_blocks[i]<=0;entry_next[i]<=0;
                entry_epoch[i]<=0;
            end
        end else begin
            if(preview_request) preview_pending<=1;
            preview_start<=0;preview_done<=0;
            if(page_request) begin
                page_pending<=1;
                page_notation_pending<=page_notation;
                page_index_pending<=page_index;
                page_token_pending<=page_request_token;
            end
            page_start<=0;page_begin<=0;page_done<=0;
            if(request_valid && state!=S_READY) begin
                queued_valid<=1;queued_type<=request_type;
                queued_session<=request_session;
                queued_seq<=request_seq;queued_len<=request_len;
            end
            mount_start<=0;image_start<=0;copy_start<=0;
            write_start<=0;scan_start<=0;validate_start<=0;
            dup_start<=0;reply_valid<=0;
            case(state)
                S_BOOT:begin
                    if(dev_init_done) state<=S_MOUNT_LAUNCH;
                    else if(boot_ticks==27'd100000000) begin
                        card_fault<=1;state<=S_READY;
                    end else boot_ticks<=boot_ticks+1'b1;
                end
                S_MOUNT_LAUNCH:begin
                    owner<=O_MOUNT;mount_start<=1;
                    state<=S_MOUNT_WAIT;
                end
                S_MOUNT_WAIT:if(mount_done) begin
                    if(!mounted || mount_io_error) begin
                        card_fault<=1;owner<=O_NONE;state<=S_READY;
                    end else begin
                        card_fault<=0;
                        active_copy_b<=mount_b_valid &&
                            (!mount_a_valid || mount_b_gen>=mount_a_gen);
                        generation<=mount_generation;
                        highwater<=mount_count;
                        state<=S_IMAGE_LAUNCH;
                    end
                end
                S_IMAGE_LAUNCH:begin
                    owner<=O_IMAGE;image_start<=1;
                    state<=S_IMAGE_WAIT;
                end
                S_IMAGE_WAIT:if(image_done) begin
                    if(image_failed) begin
                        card_fault<=1;owner<=O_NONE;state<=S_READY;
                    end else begin
                        parse_slot<=0;parse_pos<=0;
                        if(highwater==0) begin
                            owner<=O_NONE;state<=S_READY;
                        end else state<=S_PARSE_PREFETCH;
                    end
                end
                S_PARSE_PREFETCH:state<=S_PARSE;
                S_PARSE:begin
                    if(parse_pos<16)
                        entry_uuid[parse_slot]
                            [127-8*parse_pos -: 8]<=image_byte;
                    else case(parse_pos)
                        16:entry_state[parse_slot]<=image_byte;
                        18,19:entry_title_len[parse_slot]
                            [8*(parse_pos-18) +: 8]<=image_byte;
                        20,21,22,23:entry_total[parse_slot]
                            [8*(parse_pos-20) +: 8]<=image_byte;
                        24,25,26,27:entry_crc[parse_slot]
                            [8*(parse_pos-24) +: 8]<=image_byte;
                        28,29,30,31:entry_caps[parse_slot]
                            [8*(parse_pos-28) +: 8]<=image_byte;
                        32,33,34,35:entry_blocks[parse_slot]
                            [8*(parse_pos-32) +: 8]<=image_byte;
                        40,41,42,43,44,45,46,47:
                            entry_epoch[parse_slot]
                            [8*(parse_pos-40) +: 8]<=image_byte;
                        default:begin end
                    endcase
                    if(parse_pos==9'd447) state<=S_PARSE_CHECK;
                    else begin
                        parse_pos<=parse_pos+1'b1;
                        state<=S_PARSE_PREFETCH;
                    end
                end
                S_PARSE_CHECK:begin
                    if(entry_state[parse_slot]!=0 &&
                       (entry_state[parse_slot]>2 ||
                        entry_uuid[parse_slot]==0 ||
                        entry_title_len[parse_slot]==0 ||
                        entry_title_len[parse_slot]>384 ||
                        entry_total[parse_slot]==0 ||
                        entry_total[parse_slot]>32'd2097152 ||
                        entry_blocks[parse_slot]!=
                            ((entry_total[parse_slot]+32'd511)>>9) ||
                        entry_epoch[parse_slot]==0 ||
                        (entry_caps[parse_slot]&32'hfffffff8)!=0)) begin
                        card_fault<=1;owner<=O_NONE;state<=S_READY;
                    end else if(parse_slot+1'b1==highwater) begin
                        recover_slot<=0;owner<=O_NONE;
                        state<=S_RECOVER;
                    end else begin
                        parse_slot<=parse_slot+1'b1;
                        parse_pos<=0;state<=S_PARSE_PREFETCH;
                    end
                end
                S_RECOVER:begin
                    if(recover_slot>=highwater) begin
                        owner<=O_NONE;state<=S_READY;
                    end else if(entry_state[recover_slot]==1) begin
                        work_slot<=recover_slot;
                        owner<=O_SCAN;scan_start<=1;
                        state<=S_RECOVER_WAIT;
                    end else begin
                        if(entry_state[recover_slot]==2)
                            entry_next[recover_slot]<=
                                entry_blocks[recover_slot];
                        recover_slot<=recover_slot+1'b1;
                    end
                end
                S_RECOVER_WAIT:if(scan_done) begin
                    if(scan_io_failed || scan_bad_spec) begin
                        card_fault<=1;owner<=O_NONE;state<=S_READY;
                    end else begin
                        entry_next[recover_slot]<=scan_next;
                        recover_slot<=recover_slot+1'b1;
                        owner<=O_NONE;state<=S_RECOVER;
                    end
                end
                S_READY:if(request_valid || queued_valid) begin
                    queued_valid<=0;
                    held_req_type<=queued_valid ? queued_type:request_type;
                    held_session<=queued_valid ?
                        queued_session:request_session;
                    held_seq<=queued_valid ? queued_seq:request_seq;
                    held_req_len<=queued_valid ? queued_len:request_len;
                    load_pos<=0;
                    req_hash<=crc_byte(crc_byte(32'hffffffff,
                        queued_valid ? queued_type:request_type),
                        queued_valid ? queued_len[7:0]:request_len[7:0]);
                    req_uuid<=0;req_total<=0;req_crc<=0;
                    req_blocks<=0;req_caps<=0;req_block_index<=0;
                    req_generation<=0;req_cursor<=0;
                    req_block_bytes<=0;req_major<=0;
                    req_title_len<=0;req_limit<=0;req_reserved<=0;
                    utf8_need<=0;utf8_lead<=0;scalar_count<=0;
                    utf8_first<=0;title_bad<=0;
                    replay_response<=0;
                    reject_response<=0;
                    match_found<=0;free_found<=0;
                    match_slot<=0;free_slot<=0;lookup_slot<=0;
                    list_candidate<=0;list_candidate_found<=0;
                    later_found<=0;later_cursor<=32'hffffffff;
                    state<=S_LOAD_READ;
                end else if(preview_pending) begin
                    preview_pending<=0;
                    preview_available<=0;
                    if(!card_fault && entry_state[0]==2) begin
                        work_slot<=0;
                        owner<=O_NOTE;
                        preview_start<=1;
                        state<=S_NOTE_WAIT;
                    end else preview_done<=1;
                end else if(page_pending) begin
                    page_pending<=0;
                    page_token_active<=page_token_pending;
                    page_available<=0;
                    page_result<=0;
                    page_begin<=1;
                    if(!card_fault && entry_state[0]==2) begin
                        owner<=O_PAGE;
                        page_start<=1;
                        state<=S_PAGE_WAIT;
                    end else begin
                        page_result<=4'd3;
                        page_completed_token<=page_token_pending;
                        page_done<=1;
                    end
                end
                S_NOTE_WAIT:if(preview_read_done) begin
                    preview_available<=!preview_read_io_failed &&
                        !preview_bad_spec && preview_descriptor_valid &&
                        preview_total_notes!=0;
                    preview_done<=1;
                    owner<=O_NONE;
                    state<=S_READY;
                end
                S_PAGE_WAIT:if(page_read_done) begin
                    page_selected_index<=page_read_selected_index;
                    page_completed_token<=page_token_active;
                    page_available<=page_read_found &&
                        !page_read_io_failed && !page_bad_spec;
                    page_result<=page_read_io_failed ? 4'd4 :
                        page_bad_input ? 4'd8 :
                        page_bad_spec ?
                            (page_invalid_reason==3'd1 &&
                             entry_total[0]<32'd57600 ? 4'd12 :
                             page_invalid_reason==3'd2 ? 4'd9 :
                             page_invalid_reason==3'd3 ? 4'd10 :
                             page_invalid_reason==3'd4 ? 4'd11 : 4'd5) :
                        !page_read_found ? 4'd6 : 4'd7;
                    page_done<=1;
                    owner<=O_NONE;
                    state<=S_READY;
                end
                S_LOAD_READ:state<=S_LOAD_PREFETCH;
                S_LOAD_PREFETCH:begin
                    if(load_pos>=held_req_len) state<=S_LOOKUP;
                    else begin
                        load_request_byte_q<=request_byte;
                        state<=S_LOAD;
                    end
                end
                S_LOAD:begin
                    if(load_pos>=held_req_len) state<=S_LOOKUP;
                    else begin
                        req_hash<=crc_byte(req_hash,load_request_byte_q);
                        if(held_req_type>=8'h10 &&
                           held_req_type<=8'h14 && load_pos<16)
                            req_uuid[127-8*load_pos -: 8]<=load_request_byte_q;
                        if(held_req_type==8'h03) case(load_pos)
                            0,1,2,3:req_generation
                                [8*load_pos +: 8]<=load_request_byte_q;
                            4,5,6,7:req_cursor
                                [8*(load_pos-4) +: 8]<=load_request_byte_q;
                            8,9:req_limit
                                [8*(load_pos-8) +: 8]<=load_request_byte_q;
                            10,11:req_reserved
                                [8*(load_pos-10) +: 8]<=load_request_byte_q;
                            default:begin end
                        endcase
                        if(held_req_type==8'h10 ||
                           held_req_type==8'h12) begin
                            if(load_pos>=16 && load_pos<20)
                                req_total[8*(load_pos-16) +: 8]
                                    <=load_request_byte_q;
                            if(load_pos>=20 && load_pos<24)
                                req_crc[8*(load_pos-20) +: 8]
                                    <=load_request_byte_q;
                        end
                        if(held_req_type==8'h11 &&
                           load_pos>=16 && load_pos<20)
                            req_block_index[8*(load_pos-16) +: 8]
                                <=load_request_byte_q;
                        if(held_req_type==8'h10) begin
                            case(load_pos)
                                24,25:req_block_bytes
                                    [8*(load_pos-24) +: 8]<=load_request_byte_q;
                                26,27:req_major
                                    [8*(load_pos-26) +: 8]<=load_request_byte_q;
                                28,29,30,31:req_blocks
                                    [8*(load_pos-28) +: 8]<=load_request_byte_q;
                                32,33,34,35:req_caps
                                    [8*(load_pos-32) +: 8]<=load_request_byte_q;
                                36,37:req_title_len
                                    [8*(load_pos-36) +: 8]<=load_request_byte_q;
                                38,39:req_reserved
                                    [8*(load_pos-38) +: 8]<=load_request_byte_q;
                                default:begin end
                            endcase
                            if(load_pos>=40) begin
                                if(utf8_need!=0) begin
                                    if(load_request_byte_q<8'h80 ||
                                       load_request_byte_q>8'hbf ||
                                       (utf8_first && utf8_lead==8'he0 &&
                                        load_request_byte_q<8'ha0) ||
                                       (utf8_first && utf8_lead==8'hed &&
                                        load_request_byte_q>=8'ha0) ||
                                       (utf8_first && utf8_lead==8'hf0 &&
                                        load_request_byte_q<8'h90) ||
                                       (utf8_first && utf8_lead==8'hf4 &&
                                        load_request_byte_q>=8'h90)) title_bad<=1;
                                    utf8_need<=utf8_need-1'b1;
                                    utf8_first<=0;
                                end else begin
                                    scalar_count<=scalar_count+1'b1;
                                    if(load_request_byte_q<8'h20 ||
                                       load_request_byte_q==8'h7f ||
                                       load_request_byte_q==8'hc0 ||
                                       load_request_byte_q==8'hc1 ||
                                       load_request_byte_q>8'hf4) title_bad<=1;
                                    else if(load_request_byte_q>=8'hc2 &&
                                            load_request_byte_q<=8'hdf) begin
                                        utf8_need<=1;utf8_lead<=load_request_byte_q;
                                        utf8_first<=1;
                                    end else if(load_request_byte_q>=8'he0 &&
                                                load_request_byte_q<=8'hef) begin
                                        utf8_need<=2;utf8_lead<=load_request_byte_q;
                                        utf8_first<=1;
                                    end else if(load_request_byte_q>=8'hf0 &&
                                                load_request_byte_q<=8'hf4) begin
                                        utf8_need<=3;utf8_lead<=load_request_byte_q;
                                        utf8_first<=1;
                                    end else if(load_request_byte_q>=8'h80)
                                        title_bad<=1;
                                end
                            end
                        end
                        load_pos<=load_pos+1'b1;
                        state<=S_LOAD_READ;
                    end
                end
                S_LOOKUP:begin
                    if(entry_state[lookup_slot]!=0 &&
                       entry_uuid[lookup_slot]==req_uuid) begin
                        match_found<=1;match_slot<=lookup_slot;
                    end
                    if(!free_found && entry_state[lookup_slot]==0) begin
                        free_found<=1;free_slot<=lookup_slot;
                    end
                    if(lookup_slot<highwater &&
                       lookup_slot>=req_cursor &&
                       entry_state[lookup_slot]!=0) begin
                        if(!list_candidate_found) begin
                            list_candidate_found<=1;
                            list_candidate<=lookup_slot;
                        end else if(!later_found) begin
                            later_found<=1;
                            later_cursor<={29'd0,lookup_slot};
                        end
                    end
                    if(lookup_slot==MAX_SLOTS-1) state<=S_DATA_PREP_INDEX;
                    else lookup_slot<=lookup_slot+1'b1;
                end
                S_DATA_PREP_INDEX:begin
                    data_block_in_range<=match_found &&
                        req_block_index<entry_blocks[match_slot];
                    data_block_last<=req_block_index+1'b1==
                        entry_blocks[match_slot];
                    state<=S_DATA_PREP_BYTES;
                end
                S_DATA_PREP_BYTES:begin
                    expected_data_bytes<=!data_block_in_range ? 32'd0 :
                        data_block_last ?
                        entry_total[match_slot]-(req_block_index<<9) :
                        32'd512;
                    state<=S_HANDLE;
                end
                S_HANDLE:begin
                    if(previous_valid && held_session==previous_session &&
                       held_seq==previous_seq) begin
                        if(held_req_type==previous_type &&
                           held_req_len==previous_len &&
                           req_hash==previous_hash) begin
                            reply_mode<=previous_reply_mode;
                            reply_type<=previous_reply_type;
                            reply_len<=previous_reply_len;
                            error_code<=previous_error_code;
                            error_next<=previous_error_next;
                            replay_response<=1;state<=S_RESPOND;
                        end else begin
                            reject_response<=1;
                            error_response(16'h000d,32'hffffffff);
                        end
                    end else if(previous_valid &&
                            held_session==previous_session &&
                            held_seq<previous_seq) begin
                        reject_response<=1;
                        error_response(16'h000d,32'hffffffff);
                    end
                    else if(previous_valid &&
                            held_session!=previous_session &&
                            held_req_type!=8'h01) begin
                        reject_response<=1;
                        error_response(16'h000d,32'hffffffff);
                    end
                    else if(card_fault)
                        error_response(16'h0008,32'hffffffff);
                    else case(held_req_type)
                        8'h01:if(held_req_len==0)
                            success_response(R_CAPS,11'd42);
                        else error_response(16'h000d,32'hffffffff);
                        8'h02:if(held_req_len==0)
                            success_response(R_STATUS,11'd44);
                        else error_response(16'h000d,32'hffffffff);
                        8'h03:begin
                            if(held_req_len!=12 || req_reserved!=0 ||
                               req_limit==0 || req_limit>16 ||
                               req_cursor>MAX_SLOTS ||
                               (req_generation==0 && req_cursor!=0))
                                error_response(16'h000d,32'hffffffff);
                            else if(req_generation!=0 &&
                                    req_generation!=generation)
                                error_response(16'h000b,32'hffffffff);
                            else begin
                                list_found<=list_candidate_found;
                                list_slot<=list_candidate;
                                list_next<=later_cursor;
                                success_response(R_LIST,
                                    list_candidate_found ?
                                    11'd60+entry_title_len[list_candidate]:
                                    11'd16);
                            end
                        end
                        8'h10:begin
                            if(req_major!=2)
                                error_response(16'h0003,32'hffffffff);
                            else if((req_caps&32'hfffffff8)!=0)
                                error_response(16'h0004,32'hffffffff);
                            else if(held_req_len<41 ||
                                    req_title_len==0 ||
                                    req_title_len>384 ||
                                    held_req_len!=11'd40+req_title_len ||
                                    req_reserved!=0 ||
                                    req_uuid==0 ||req_total<64 ||
                                    req_total>32'd2097152 ||
                                    req_caps==0 ||
                                    req_block_bytes!=512 ||
                                    req_blocks!=((req_total+511)>>9) ||
                                    title_bad || utf8_need!=0 ||
                                    scalar_count==0 ||scalar_count>128)
                                error_response(16'h000d,32'hffffffff);
                            else if(match_found) begin
                                if(entry_state[match_slot]==2)
                                    error_response(16'h000c,
                                        32'hffffffff);
                                else if(entry_total[match_slot]!=req_total ||
                                        entry_crc[match_slot]!=req_crc ||
                                        entry_caps[match_slot]!=req_caps ||
                                        entry_blocks[match_slot]!=req_blocks)
                                    error_response(16'h0009,
                                        32'hffffffff);
                                else if(active_valid &&
                                        active_slot!=match_slot)
                                    error_response(16'h0001,
                                        32'hffffffff);
                                else begin
                                    active_valid<=1;
                                    active_slot<=match_slot;
                                    reply_slot<=match_slot;
                                    success_response(R_PROGRESS,11'd32);
                                end
                            end else if(active_valid)
                                error_response(16'h0001,32'hffffffff);
                            else if(!free_found)
                                error_response(16'h0002,32'hffffffff);
                            else begin
                                pending_slot<=free_slot;
                                work_slot<=free_slot;
                                reply_slot<=free_slot;
                                pending_generation<=generation+1'b1;
                                pending_highwater<=
                                    (free_slot>=highwater) ?
                                    free_slot+1'b1:highwater;
                                mutation<=M_BEGIN;
                                mutate_pos<=0;mutate_title_addr<=10'd40;
                                state<=S_MUTATE_READ;
                            end
                        end
                        8'h11:begin
                            if(held_req_len<21 ||held_req_len>532 ||
                               req_uuid==0 || !match_found ||
                               entry_state[match_slot]!=1)
                                error_response(16'h000a,
                                    32'hffffffff);
                            else if(!active_valid ||
                                    active_slot!=match_slot)
                                error_response(16'h0001,
                                    32'hffffffff);
                            else if(req_block_index>=
                                    entry_blocks[match_slot] ||
                                    expected_data_bytes==0 ||
                                    held_req_len!=20+expected_data_bytes)
                                error_response(16'h0005,
                                    entry_next[match_slot]);
                            else if(req_block_index>
                                    entry_next[match_slot])
                                error_response(16'h0005,
                                    entry_next[match_slot]);
                            else begin
                                work_slot<=match_slot;
                                reply_slot<=match_slot;
                                data_index<=req_block_index[11:0];
                                data_bytes<=expected_data_bytes[9:0];
                                if(req_block_index<entry_next[match_slot])
                                    state<=S_DUP_LAUNCH;
                                else state<=S_WRITE_LAUNCH;
                            end
                        end
                        8'h12:begin
                            if(held_req_len!=24 ||req_uuid==0)
                                error_response(16'h000d,
                                    32'hffffffff);
                            else if(!match_found)
                                error_response(16'h000a,
                                    32'hffffffff);
                            else if(entry_total[match_slot]!=req_total ||
                                    entry_crc[match_slot]!=req_crc)
                                error_response(16'h0009,
                                    32'hffffffff);
                            else if(entry_state[match_slot]==2) begin
                                reply_slot<=match_slot;
                                success_response(R_COMMIT,11'd28);
                            end else if(!active_valid ||
                                    active_slot!=match_slot)
                                error_response(16'h0001,
                                    32'hffffffff);
                            else if(entry_next[match_slot]!=
                                    entry_blocks[match_slot])
                                error_response(16'h0005,
                                    entry_next[match_slot]);
                            else begin
                                work_slot<=match_slot;
                                reply_slot<=match_slot;
                                state<=S_VALIDATE_LAUNCH;
                            end
                        end
                        8'h13:begin
                            if(held_req_len!=16 ||req_uuid==0)
                                error_response(16'h000d,
                                    32'hffffffff);
                            else if(!match_found ||
                                    entry_state[match_slot]!=1)
                                error_response(16'h000a,
                                    32'hffffffff);
                            else begin
                                if(active_valid &&
                                   active_slot==match_slot)
                                    active_valid<=0;
                                reply_slot<=match_slot;
                                success_response(R_PROGRESS,11'd32);
                            end
                        end
                        8'h14:begin
                            if(held_req_len!=16 ||req_uuid==0)
                                error_response(16'h000d,
                                    32'hffffffff);
                            else if(!match_found) begin
                                deleted_flag<=0;
                                success_response(R_DELETE,11'd24);
                            end else begin
                                pending_slot<=match_slot;
                                work_slot<=match_slot;
                                pending_generation<=generation+1'b1;
                                pending_highwater<=highwater;
                                mutation<=M_DELETE;mutate_pos<=0;
                                deleted_flag<=1;state<=S_MUTATE_READ;
                            end
                        end
                        default:error_response(16'h000d,
                            32'hffffffff);
                    endcase
                end
                S_MUTATE_READ:state<=S_MUTATE;
                S_MUTATE:begin
                    if(mutation==M_BEGIN && mutate_pos>=9'd48)
                        mutate_title_addr<=mutate_title_addr+1'b1;
                    if((mutation==M_COMMIT && mutate_pos==9'd16) ||
                       (mutation!=M_COMMIT && mutate_pos==9'd447))
                        state<=S_PUBLISH_LAUNCH;
                    else begin
                        mutate_pos<=mutate_pos+1'b1;
                        state<=S_MUTATE_READ;
                    end
                end
                S_PUBLISH_LAUNCH:begin
                    owner<=O_COPY;copy_start<=1;
                    state<=S_PUBLISH_WAIT;
                end
                S_PUBLISH_WAIT:if(copy_done) begin
                    if(copy_failed) begin
                        card_fault<=1;owner<=O_NONE;
                        error_response(16'h0008,32'hffffffff);
                    end else state<=S_CONFIRM_LAUNCH;
                end
                S_CONFIRM_LAUNCH:begin
                    owner<=O_MOUNT;mount_start<=1;
                    state<=S_CONFIRM_WAIT;
                end
                S_CONFIRM_WAIT:if(mount_done) begin
                    if(mount_io_error || !mounted ||
                       mount_generation!=pending_generation ||
                       mount_count!=pending_highwater ||
                       (active_copy_b ? !mount_a_valid:
                                        !mount_b_valid)) begin
                        card_fault<=1;owner<=O_NONE;
                        error_response(16'h0008,32'hffffffff);
                    end else begin
                        generation<=pending_generation;
                        highwater<=pending_highwater;
                        active_copy_b<=!active_copy_b;
                        owner<=O_NONE;
                        case(mutation)
                            M_BEGIN:begin
                                entry_uuid[pending_slot]<=req_uuid;
                                entry_state[pending_slot]<=1;
                                entry_title_len[pending_slot]
                                    <=req_title_len;
                                entry_total[pending_slot]<=req_total;
                                entry_crc[pending_slot]<=req_crc;
                                entry_caps[pending_slot]<=req_caps;
                                entry_blocks[pending_slot]<=req_blocks;
                                entry_next[pending_slot]<=0;
                                entry_epoch[pending_slot]<=
                                    {29'd0,pending_slot+1'b1,
                                     pending_generation};
                                active_valid<=1;
                                active_slot<=pending_slot;
                                reply_slot<=pending_slot;
                                success_response(R_PROGRESS,11'd32);
                            end
                            M_COMMIT:begin
                                entry_state[pending_slot]<=2;
                                if(active_valid &&
                                   active_slot==pending_slot)
                                    active_valid<=0;
                                reply_slot<=pending_slot;
                                success_response(R_COMMIT,11'd28);
                            end
                            M_DELETE:begin
                                entry_uuid[pending_slot]<=0;
                                entry_state[pending_slot]<=0;
                                entry_title_len[pending_slot]<=0;
                                entry_total[pending_slot]<=0;
                                entry_crc[pending_slot]<=0;
                                entry_caps[pending_slot]<=0;
                                entry_blocks[pending_slot]<=0;
                                entry_next[pending_slot]<=0;
                                entry_epoch[pending_slot]<=0;
                                if(active_valid &&
                                   active_slot==pending_slot)
                                    active_valid<=0;
                                success_response(R_DELETE,11'd24);
                            end
                        endcase
                    end
                end
                S_WRITE_LAUNCH:begin
                    owner<=O_WRITE;write_start<=1;
                    state<=S_WRITE_WAIT;
                end
                S_WRITE_WAIT:if(write_done) begin
                    owner<=O_NONE;
                    if(write_failed)
                        error_response(16'h0008,32'hffffffff);
                    else begin
                        entry_next[work_slot]<=entry_next[work_slot]+1'b1;
                        success_response(R_PROGRESS,11'd32);
                    end
                end
                S_VALIDATE_LAUNCH:begin
                    owner<=O_VALIDATE;validate_start<=1;
                    state<=S_VALIDATE_WAIT;
                end
                S_VALIDATE_WAIT:if(validate_done) begin
                    owner<=O_NONE;
                    if(validate_io_failed)
                        error_response(16'h0008,32'hffffffff);
                    else if(validate_bad_crc)
                        error_response(16'h0006,32'hffffffff);
                    else if(validate_bad_package)
                        error_response(16'h0007,32'hffffffff);
                    else begin
                        mutation<=M_COMMIT;
                        pending_slot<=work_slot;
                        pending_generation<=generation+1'b1;
                        pending_highwater<=highwater;
                        mutate_pos<=9'd16;
                        state<=S_MUTATE_READ;
                    end
                end
                S_DUP_LAUNCH:begin
                    owner<=O_DUP;dup_addr<=0;
                    if(!dup_guard)
                        error_response(16'h0008,32'hffffffff);
                    else begin
                        dup_start<=1;state<=S_DUP_WAIT;
                    end
                end
                S_DUP_WAIT:if(dev_done) begin
                    if(dev_error!=0) begin
                        owner<=O_NONE;
                        error_response(16'h0008,32'hffffffff);
                    end else begin
                        compare_pos<=0;state<=S_DUP_READ;
                    end
                end
                S_DUP_READ:state<=S_DUP_PREFETCH;
                S_DUP_PREFETCH:begin
                    dup_request_byte_q<=request_byte;
                    dup_device_byte_q<=dev_rdata;
                    state<=S_DUP_COMPARE;
                end
                S_DUP_COMPARE:begin
                    if(dup_device_byte_q!=dup_request_byte_q) begin
                        owner<=O_NONE;
                        error_response(16'h0009,32'hffffffff);
                    end else if(compare_pos+1'b1==data_bytes) begin
                        owner<=O_NONE;
                        success_response(R_PROGRESS,11'd32);
                    end else begin
                        compare_pos<=compare_pos+1'b1;
                        state<=S_DUP_READ;
                    end
                end
                S_RESPOND:begin
                    reply_valid<=1;
                    if(!replay_response && !reject_response) begin
                        previous_valid<=1;
                        previous_session<=held_session;
                        previous_seq<=held_seq;
                        previous_hash<=req_hash;
                        previous_len<=held_req_len;
                        previous_type<=held_req_type;
                        previous_reply_mode<=reply_mode;
                        previous_reply_type<=reply_type;
                        previous_reply_len<=reply_len;
                        previous_error_code<=error_code;
                        previous_error_next<=error_next;
                    end
                    state<=S_REPLY_WAIT;
                end
                S_REPLY_WAIT:if(reply_addr_done) begin
                    replay_response<=0;
                    state<=S_READY;
                end
                default:state<=S_BOOT;
            endcase
        end
    end
endmodule
