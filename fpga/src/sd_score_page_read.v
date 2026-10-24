// Read one requested notation page of one committed PSC2 slot.
// The SD device is exclusive to this reader while busy; no writes are issued.
// Emits 57,600 byte-indexed MONO1 bytes for an external page cache. The
// caller must not expose the page until done and found are both asserted.
module sd_score_page_read (
    input wire clk,rst_n,start,
    input wire [2:0] slot,
    input wire [1:0] notation,
    input wire [5:0] page_index,
    input wire [31:0] total_bytes,sector_count,
    input wire block_ready,block_done,
    input wire [7:0] block_error,buffer_rdata,
    output reg block_start,
    output wire block_write,
    output wire [31:0] block_lba,
    output wire block_guard_valid,
    output wire [8:0] buffer_addr,
    output reg bitmap_byte_valid,
    output reg [15:0] bitmap_byte_index,
    output reg [7:0] bitmap_byte,
    output reg done,found,io_failed,invalid_spec,invalid_input,
    output reg [5:0] selected_page_index,
    output reg [2:0] invalid_reason,
    // Retain the diagnostic interface for build identification. The indexer
    // validates page length before publication, so length-error snapshots
    // are intentionally unreachable in this reader.
    output reg diag_err_valid,diag_err_page_found,diag_err_index_clear,
    output reg [2:0] diag_err_state,
    output reg [31:0] diag_err_length,diag_err_offset,diag_err_total,
    output wire diag_pub_valid,
    output wire [31:0] diag_pub_length,diag_pub_byte_offset,
    output wire [4:0] diag_pub_page_field
);
    localparam IDLE=0,REQUEST=1,WAIT_BLOCK=2,SCAN=3,
        STREAM=4,FINISH=5,CHECK_INDEX=6,CHECK_INDEX_DRAIN=7,
        INDEX_RESOLVE=8,INDEX_FINAL=9;
    reg [3:0] state;
    reg [2:0] held_slot;
    reg [1:0] held_notation;
    reg [5:0] held_page_index;
    reg [31:0] held_total,absolute_pos,last_pos;
    reg [12:0] sector_index;
    reg [8:0] byte_index;
    reg [15:0] stream_count;
    reg streaming,index_clear,index_scan_done;
    reg scan_valid_q;
    reg [31:0] scan_offset_q;
    reg [7:0] scan_data_q;
    wire [31:0] lba;
    wire lba_valid;
    wire page_found,page_scan_complete;
    wire [31:0] page_id,bitmap_offset,bitmap_length;
    wire [5:0] indexed_page_index;
    assign block_write=1'b0;
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    assign buffer_addr=byte_index;
    sd_storage_lba address_guard(
        .region(2'd1),.directory_b(1'b0),.slot(held_slot),
        .index(sector_index),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
    psc2_page_index indexer(
        .clk(clk),.rst_n(rst_n),.clear(index_clear),
        // Register the SD-buffer byte before descriptor decoding.  This
        // breaks the owner/address/RAM/compare path at a clock boundary.
        .notation(held_notation),.target_index(held_page_index),
        .scan_done(index_scan_done),.byte_valid(scan_valid_q),
        .byte_offset(scan_offset_q),.byte_data(scan_data_q),
        .page_found(page_found),.page_scan_complete(page_scan_complete),
        .page_id(page_id),
        .selected_index(indexed_page_index),
        .bitmap_offset(bitmap_offset),.bitmap_length(bitmap_length),
        .diag_pub_valid(diag_pub_valid),
        .diag_pub_length(diag_pub_length),
        .diag_pub_byte_offset(diag_pub_byte_offset),
        .diag_pub_page_field(diag_pub_page_field)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;held_slot<=0;held_notation<=0;
            held_page_index<=0;held_total<=0;
            absolute_pos<=0;last_pos<=0;sector_index<=0;byte_index<=0;
            streaming<=0;index_clear<=0;index_scan_done<=0;
            block_start<=0;
            scan_valid_q<=0;scan_offset_q<=0;scan_data_q<=0;
            bitmap_byte_valid<=0;bitmap_byte_index<=0;stream_count<=0;
            bitmap_byte<=0;done<=0;found<=0;selected_page_index<=0;
            io_failed<=0;invalid_spec<=0;invalid_input<=0;
            invalid_reason<=0;
            diag_err_valid<=0;diag_err_page_found<=0;
            diag_err_index_clear<=0;diag_err_state<=0;
            diag_err_length<=0;diag_err_offset<=0;diag_err_total<=0;
        end else begin
            block_start<=0;bitmap_byte_valid<=0;done<=0;
            scan_valid_q<=0;
            index_clear<=0;index_scan_done<=0;
            case(state)
                IDLE:if(start) begin
                    io_failed<=0;invalid_spec<=0;invalid_input<=0;found<=0;
                    invalid_reason<=0;
                    held_slot<=slot;held_notation<=notation;
                    held_page_index<=page_index;
                    held_total<=total_bytes;absolute_pos<=0;
                    last_pos<=total_bytes-32'd1;
                    sector_index<=0;byte_index<=0;
                    bitmap_byte_index<=0;stream_count<=0;
                    streaming<=0;index_clear<=1;
                    if(slot>=6 || (notation!=1 && notation!=2) ||
                       total_bytes<96 || total_bytes>32'd2097152) begin
                        invalid_spec<=1;invalid_input<=1;state<=FINISH;
                    end else state<=REQUEST;
                end
                REQUEST:if(!streaming && absolute_pos!=0 &&
                           page_scan_complete) begin
                    index_scan_done<=1;state<=INDEX_RESOLVE;
                end else if(block_ready) begin
                    if(!lba_valid) begin io_failed<=1;state<=FINISH; end
                    else begin block_start<=1;state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK:if(block_done) begin
                    if(block_error!=0) begin io_failed<=1;state<=FINISH; end
                    else if(!streaming && page_scan_complete) begin
                        index_scan_done<=1;state<=INDEX_RESOLVE;
                    end
                    else state<=streaming ? STREAM:SCAN;
                end
                SCAN,CHECK_INDEX,CHECK_INDEX_DRAIN,INDEX_FINAL:begin
                    if(page_found) begin
                        // The indexer publishes only a validated 57,600-byte
                        // span; check its placement in this file, not its
                        // already-validated length a second time.
                        if(held_total<32'd57600 ||
                           bitmap_offset>=held_total ||
                           bitmap_offset>held_total-32'd57600) begin
                            invalid_spec<=1;
                            if(held_total<32'd57600) invalid_reason<=1;
                            else if(bitmap_offset>=held_total) invalid_reason<=2;
                            else invalid_reason<=4;
                            state<=FINISH;
                        end else begin
                            streaming<=1;
                            selected_page_index<=indexed_page_index;
                            sector_index<=bitmap_offset[21:9];
                            byte_index<=bitmap_offset[8:0];
                            stream_count<=0;
                            state<=REQUEST;
                        end
                    end else if(state==INDEX_FINAL) begin
                        // No valid PAGE of this notation exists.
                        state<=FINISH;
                    end else if(state==SCAN && page_scan_complete) begin
                        index_scan_done<=1;
                        state<=INDEX_RESOLVE;
                    end else if(state==CHECK_INDEX_DRAIN) begin
                        index_scan_done<=1;
                        state<=INDEX_RESOLVE;
                    end else if(state==CHECK_INDEX) begin
                        // The last byte was registered in SCAN and consumed
                        // by the indexer on this edge. Observe its result on
                        // the next edge before deciding that PAGE is absent.
                        state<=CHECK_INDEX_DRAIN;
                    end else if(absolute_pos==last_pos) begin
                        scan_valid_q<=1;
                        scan_offset_q<=absolute_pos;
                        scan_data_q<=buffer_rdata;
                        state<=CHECK_INDEX;
                    end else begin
                        scan_valid_q<=1;
                        scan_offset_q<=absolute_pos;
                        scan_data_q<=buffer_rdata;
                        absolute_pos<=absolute_pos+1'b1;
                        if(byte_index==9'd511) begin
                            sector_index<=sector_index+1'b1;
                            byte_index<=0;state<=REQUEST;
                        end else byte_index<=byte_index+1'b1;
                    end
                end
                INDEX_RESOLVE:state<=INDEX_FINAL;
                STREAM:begin
                    bitmap_byte_valid<=1;
                    bitmap_byte<=buffer_rdata;
                    bitmap_byte_index<=stream_count;
                    if(stream_count==16'd57599) begin
                        found<=1;state<=FINISH;
                    end else begin
                        stream_count<=stream_count+1'b1;
                        if(byte_index==9'd511) begin
                            sector_index<=sector_index+1'b1;
                            byte_index<=0;state<=REQUEST;
                        end else byte_index<=byte_index+1'b1;
                    end
                end
                FINISH:begin done<=1;state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
