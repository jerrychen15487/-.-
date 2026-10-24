// Explicit one-time diagnostic entry, only for the isolated SRAM test top.
// Caller must first verify empty B generation 2. Publishes A generation 3,
// commit sector last; B remains the previously valid rollback copy.
// The entry is NOT a PSC2 song and must never appear as a playable song.
module sd_directory_diag_seed (
    input wire clk, input wire rst_n, input wire start,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    input wire [31:0] sector_count,
    output reg block_start, output wire [31:0] block_lba,
    output wire block_guard_valid,
    output reg buffer_we, output reg [8:0] buffer_addr,
    output reg [7:0] buffer_wdata,
    output reg done, output reg failed
);
    localparam IDLE=0,FILL=1,REQUEST=2,WAIT_BLOCK=3,ADVANCE=4,
        FINISH=5,FAIL=6;
    reg [2:0] state,sector_index;
    reg [8:0] byte_index;
    reg [31:0] crc;
    wire [31:0] lba;
    wire lba_valid;
    sd_storage_lba address_guard (
        .region(2'd0),.directory_b(1'b0),.slot(3'd0),
        .index({10'd0,sector_index}),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] x;
        integer i;
        begin
            x=previous^{24'd0,octet};
            for(i=0;i<8;i=i+1)
                x=x[0] ? ((x>>1)^32'hedb88320) : (x>>1);
            crc_byte=x;
        end
    endfunction
    function [7:0] directory_byte;
        input [2:0] sector;
        input [8:0] address;
        input [31:0] running_crc;
        reg [11:0] offset;
        reg [31:0] final_crc;
        begin
            offset={sector,address};
            final_crc=~running_crc;
            directory_byte=0;
            if(sector==7) begin
                case(address)
                    0:directory_byte="P"; 1:directory_byte="S";
                    2:directory_byte="D"; 3:directory_byte="C";
                    4:directory_byte=3;
                    8:directory_byte=final_crc[7:0];
                    9:directory_byte=final_crc[15:8];
                    10:directory_byte=final_crc[23:16];
                    11:directory_byte=final_crc[31:24];
                    12:directory_byte=~final_crc[7:0];
                    13:directory_byte=~final_crc[15:8];
                    14:directory_byte=~final_crc[23:16];
                    15:directory_byte=~final_crc[31:24];
                    default:directory_byte=0;
                endcase
            end else begin
                case(offset)
                    0:directory_byte="P"; 1:directory_byte="S";
                    2:directory_byte="D"; 3:directory_byte="L";
                    4:directory_byte=1;
                    8:directory_byte=3;
                    12:directory_byte=1;
                    // Entry 0: UUID 54414E47-2D44-4941-472D-53434F524530.
                    16:directory_byte=8'h54; 17:directory_byte=8'h41;
                    18:directory_byte=8'h4e; 19:directory_byte=8'h47;
                    20:directory_byte=8'h2d; 21:directory_byte=8'h44;
                    22:directory_byte=8'h49; 23:directory_byte=8'h41;
                    24:directory_byte=8'h47; 25:directory_byte=8'h2d;
                    26:directory_byte=8'h53; 27:directory_byte=8'h43;
                    28:directory_byte=8'h4f; 29:directory_byte=8'h52;
                    30:directory_byte=8'h45; 31:directory_byte=8'h30;
                    32:directory_byte=1; // partial
                    34:directory_byte=4; // title length
                    37:directory_byte=2; // 512 bytes little-endian
                    40:directory_byte=8'h1f; 41:directory_byte=8'h93;
                    42:directory_byte=8'hcd; 43:directory_byte=8'h67;
                    48:directory_byte=1; // total blocks
                    53:directory_byte=2; // block_bytes=512
                    54:directory_byte=2; // package_major=2, diagnostic only
                    56:directory_byte=3; // slot epoch=3
                    64:directory_byte="D"; 65:directory_byte="I";
                    66:directory_byte="A"; 67:directory_byte="G";
                    default:directory_byte=0;
                endcase
            end
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; sector_index<=0; byte_index<=0;
            crc<=32'hffffffff; block_start<=0; buffer_we<=0;
            buffer_addr<=0; buffer_wdata<=0; done<=0; failed<=0;
        end else begin
            block_start<=0; buffer_we<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    failed<=0; sector_index<=0; byte_index<=0;
                    crc<=32'hffffffff; state<=FILL;
                end
                FILL: if(block_ready) begin
                    buffer_we<=1; buffer_addr<=byte_index;
                    buffer_wdata<=directory_byte(sector_index,byte_index,crc);
                    if(sector_index!=7)
                        crc<=crc_byte(crc,directory_byte(sector_index,byte_index,crc));
                    if(byte_index==511) state<=REQUEST;
                    else byte_index<=byte_index+1'b1;
                end
                REQUEST: begin
                    if(!block_ready || !lba_valid) begin failed<=1; state<=FAIL; end
                    else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin failed<=1; state<=FAIL; end
                    else state<=ADVANCE;
                end
                ADVANCE: begin
                    if(sector_index==7) state<=FINISH;
                    else begin
                        sector_index<=sector_index+1'b1;
                        byte_index<=0; state<=FILL;
                    end
                end
                FINISH: begin done<=1; state<=IDLE; end
                FAIL: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
