// Publish one 8-sector directory copy; content sectors first, CRC commit
// sector last. The caller must select the inactive copy and supply validated
// body bytes (offsets 16..3583). This unit alone cannot authorize a write.
module sd_directory_copy_write #(
    parameter MAX_ENTRIES=6
) (
    input wire clk, input wire rst_n, input wire start,
    input wire target_b, input wire [31:0] new_generation,
    input wire [2:0] new_entry_count,
    input wire [31:0] sector_count,
    output wire [11:0] source_addr, input wire [7:0] source_byte,
    input wire block_ready, input wire block_done,
    input wire [7:0] block_error,
    output reg block_start, output wire [31:0] block_lba,
    output wire block_guard_valid,
    output reg buffer_we, output reg [8:0] buffer_addr,
    output reg [7:0] buffer_wdata,
    output reg done, output reg failed
);
    localparam IDLE=0,FILL=1,REQUEST=2,WAIT_BLOCK=3,ADVANCE=4,
        FINISH=5,FAIL=6,PREFETCH=7;
    reg [2:0] state,sector_index;
    reg held_b;
    reg [31:0] held_generation;
    reg [2:0] held_count;
    reg [8:0] byte_index;
    reg [31:0] crc;
    wire [31:0] lba;
    wire lba_valid;
    wire [11:0] offset={sector_index,byte_index};
    assign source_addr=(sector_index==7) ? 12'd0 : offset;
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    sd_storage_lba address_guard (
        .region(2'd0),.directory_b(held_b),.slot(3'd0),
        .index({10'd0,sector_index}),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
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
        input [11:0] address;
        input [31:0] generation;
        input [2:0] count;
        input [31:0] running_crc;
        input [7:0] body_byte;
        reg [31:0] final_crc;
        begin
            final_crc=~running_crc;
            directory_byte=0;
            if(address>=12'd3584) begin
                case(address)
                    3584:directory_byte="P";
                    3585:directory_byte="S";
                    3586:directory_byte="D";
                    3587:directory_byte="C";
                    3588:directory_byte=generation[7:0];
                    3589:directory_byte=generation[15:8];
                    3590:directory_byte=generation[23:16];
                    3591:directory_byte=generation[31:24];
                    3592:directory_byte=final_crc[7:0];
                    3593:directory_byte=final_crc[15:8];
                    3594:directory_byte=final_crc[23:16];
                    3595:directory_byte=final_crc[31:24];
                    3596:directory_byte=~final_crc[7:0];
                    3597:directory_byte=~final_crc[15:8];
                    3598:directory_byte=~final_crc[23:16];
                    3599:directory_byte=~final_crc[31:24];
                    default:directory_byte=0;
                endcase
            end else if(address<16) begin
                case(address)
                    0:directory_byte="P";
                    1:directory_byte="S";
                    2:directory_byte="D";
                    3:directory_byte="L";
                    4:directory_byte=1;
                    8:directory_byte=generation[7:0];
                    9:directory_byte=generation[15:8];
                    10:directory_byte=generation[23:16];
                    11:directory_byte=generation[31:24];
                    12:directory_byte={5'd0,count};
                    default:directory_byte=0;
                endcase
            end else directory_byte=body_byte;
        end
    endfunction
    wire [7:0] next_byte=directory_byte(offset,held_generation,
        held_count,crc,source_byte);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; sector_index<=0; held_b<=0;
            held_generation<=0; held_count<=0; byte_index<=0;
            crc<=32'hffffffff; block_start<=0; buffer_we<=0;
            buffer_addr<=0; buffer_wdata<=0; done<=0; failed<=0;
        end else begin
            block_start<=0; buffer_we<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    failed<=0; held_b<=target_b;
                    held_generation<=new_generation;
                    held_count<=new_entry_count;
                    sector_index<=0; byte_index<=0;
                    crc<=32'hffffffff;
                    if(new_generation==0 || new_generation==32'hffffffff ||
                       new_entry_count>MAX_ENTRIES) begin failed<=1; state<=FAIL; end
                    else state<=PREFETCH;
                end
                PREFETCH: state<=FILL;
                FILL: if(block_ready) begin
                    buffer_we<=1; buffer_addr<=byte_index;
                    buffer_wdata<=next_byte;
                    if(sector_index!=7) crc<=crc_byte(crc,next_byte);
                    if(byte_index==9'd511) state<=REQUEST;
                    else begin
                        byte_index<=byte_index+1'b1;
                        state<=PREFETCH;
                    end
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
                        byte_index<=0; state<=PREFETCH;
                    end
                end
                FINISH: begin done<=1; state<=IDLE; end
                FAIL: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
