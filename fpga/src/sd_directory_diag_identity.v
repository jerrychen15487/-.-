// Read-only exact identity check for sector 0 of the isolated diagnostic A3.
// The caller must also require the full-copy CRC from sd_directory_mount and
// a valid empty B2 rollback copy before permitting any diagnostic writes.
module sd_directory_diag_identity (
    input wire clk, input wire rst_n, input wire start,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    input wire [31:0] sector_count,
    output reg block_start, output wire [31:0] block_lba,
    output wire block_guard_valid, output wire [8:0] buffer_addr,
    input wire [7:0] buffer_rdata,
    output reg done, output reg valid, output reg io_failed
);
    localparam IDLE=0,REQUEST=1,WAIT_BLOCK=2,CHECK=3,FINISH=4;
    reg [2:0] state;
    reg [8:0] byte_index;
    reg match_ok;
    wire [31:0] lba;
    wire lba_valid;
    sd_storage_lba address_guard (
        .region(2'd0),.directory_b(1'b0),.slot(3'd0),
        .index(13'd0),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    assign buffer_addr=byte_index;
    function [7:0] expected_byte;
        input [8:0] address;
        begin
            expected_byte=0;
            case(address)
                0:expected_byte="P"; 1:expected_byte="S";
                2:expected_byte="D"; 3:expected_byte="L";
                4:expected_byte=1;
                8:expected_byte=3;
                12:expected_byte=1;
                16:expected_byte=8'h54; 17:expected_byte=8'h41;
                18:expected_byte=8'h4e; 19:expected_byte=8'h47;
                20:expected_byte=8'h2d; 21:expected_byte=8'h44;
                22:expected_byte=8'h49; 23:expected_byte=8'h41;
                24:expected_byte=8'h47; 25:expected_byte=8'h2d;
                26:expected_byte=8'h53; 27:expected_byte=8'h43;
                28:expected_byte=8'h4f; 29:expected_byte=8'h52;
                30:expected_byte=8'h45; 31:expected_byte=8'h30;
                32:expected_byte=1;
                34:expected_byte=4;
                37:expected_byte=2;
                40:expected_byte=8'h1f; 41:expected_byte=8'h93;
                42:expected_byte=8'hcd; 43:expected_byte=8'h67;
                48:expected_byte=1;
                53:expected_byte=2;
                54:expected_byte=2;
                56:expected_byte=3;
                64:expected_byte="D"; 65:expected_byte="I";
                66:expected_byte="A"; 67:expected_byte="G";
                default:expected_byte=0;
            endcase
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; byte_index<=0; match_ok<=0;
            block_start<=0; done<=0; valid<=0; io_failed<=0;
        end else begin
            block_start<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    byte_index<=0; match_ok<=1; valid<=0; io_failed<=0;
                    state<=REQUEST;
                end
                REQUEST: if(block_ready) begin
                    if(!lba_valid) begin io_failed<=1; state<=FINISH; end
                    else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin io_failed<=1; state<=FINISH; end
                    else begin byte_index<=0; state<=CHECK; end
                end
                CHECK: begin
                    if(buffer_rdata!=expected_byte(byte_index)) match_ok<=0;
                    if(byte_index==511) begin
                        valid<=match_ok && buffer_rdata==expected_byte(byte_index);
                        state<=FINISH;
                    end else byte_index<=byte_index+1'b1;
                end
                FINISH: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
