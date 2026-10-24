// Recover the contiguous durable prefix of one partial song. Stops at the
// first missing/invalid block; SD read failures are reported separately and
// must not be converted to next_block. Caller supplies a directory-validated
// UUID, epoch and file length. No card writes are possible through this module.
module sd_score_progress_scan (
    input wire clk, input wire rst_n, input wire start,
    input wire [2:0] slot,
    input wire [31:0] total_bytes,
    input wire [127:0] uuid,
    input wire [63:0] slot_epoch,
    input wire [31:0] sector_count,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    output wire block_start, output wire block_write,
    output wire [31:0] block_lba, output wire block_guard_valid,
    output wire [8:0] buffer_addr, input wire [7:0] buffer_rdata,
    output reg done, output reg io_failed, output reg invalid_spec,
    output reg [12:0] next_block
);
    localparam IDLE=0,LAUNCH=1,WAIT_VERIFY=2,FINISH=3;
    reg [1:0] state;
    reg verify_start;
    wire verify_done, verify_valid, verify_io_failed;
    reg [2:0] held_slot;
    reg [31:0] held_total_bytes;
    reg [127:0] held_uuid;
    reg [63:0] held_epoch;
    reg [12:0] total_blocks;
    wire [31:0] computed_total_blocks=(total_bytes+32'd511)>>9;
    wire [31:0] tail_bytes=held_total_bytes-({19'd0,next_block}<<9);
    wire [9:0] expected_bytes=(next_block==total_blocks-1'b1)
        ? tail_bytes[9:0] : 10'd512;
    // A full final block has remainder 512, not zero.
    wire [9:0] final_bytes=(next_block==total_blocks-1'b1 &&
        expected_bytes==0) ? 10'd512 : expected_bytes;
    sd_score_block_verify verifier (
        .clk(clk),.rst_n(rst_n),.start(verify_start),
        .slot(held_slot),.block_index(next_block[11:0]),
        .expected_bytes(final_bytes),.uuid(held_uuid),
        .slot_epoch(held_epoch),.sector_count(sector_count),
        .block_ready(block_ready),.block_done(block_done),
        .block_error(block_error),.block_start(block_start),
        .block_write(block_write),.block_lba(block_lba),
        .block_guard_valid(block_guard_valid),
        .buffer_addr(buffer_addr),.buffer_rdata(buffer_rdata),
        .done(verify_done),.valid(verify_valid),
        .io_failed(verify_io_failed)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; verify_start<=0;
            held_slot<=0; held_total_bytes<=0;
            held_uuid<=0; held_epoch<=0; total_blocks<=0;
            next_block<=0; done<=0; io_failed<=0; invalid_spec<=0;
        end else begin
            verify_start<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    next_block<=0; io_failed<=0; invalid_spec<=0;
                    if(slot>=6 || total_bytes==0 || total_bytes>32'd2097152 ||
                       uuid==0 || slot_epoch==0) begin
                        invalid_spec<=1; state<=FINISH;
                    end else begin
                        held_slot<=slot; held_total_bytes<=total_bytes;
                        held_uuid<=uuid; held_epoch<=slot_epoch;
                        total_blocks<=computed_total_blocks[12:0];
                        state<=LAUNCH;
                    end
                end
                LAUNCH: begin verify_start<=1; state<=WAIT_VERIFY; end
                WAIT_VERIFY: if(verify_done) begin
                    if(verify_io_failed) begin
                        io_failed<=1; state<=FINISH;
                    end else if(!verify_valid) state<=FINISH;
                    else if(next_block+1'b1==total_blocks) begin
                        next_block<=next_block+1'b1; state<=FINISH;
                    end else begin
                        next_block<=next_block+1'b1; state<=LAUNCH;
                    end
                end
                FINISH: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
