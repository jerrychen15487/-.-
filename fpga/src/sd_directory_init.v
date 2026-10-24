// Explicit empty-library initializer. Writes A generation 1, then B generation 2.
// Every sector goes through the block device write+readback before advancing.
// Caller MUST assert start only after a failed clean read-only mount and user
// confirmation; this module never starts itself and never touches song slots.
module sd_directory_init (
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
    localparam S_IDLE=0,S_FILL=1,S_REQUEST=2,S_WAIT=3,S_ADVANCE=4,
        S_DONE=5,S_FAILED=6;
    reg [2:0] state;
    reg copy_b;
    reg [2:0] sector_index;
    reg [8:0] fill_index;
    reg [31:0] crc;
    wire [31:0] lba;
    wire valid;
    sd_storage_lba address_guard (
        .region(2'd0),.directory_b(copy_b),.slot(3'd0),
        .index({10'd0,sector_index}),.sector_count(sector_count),
        .lba(lba),.valid(valid)
    );
    assign block_lba=lba;
    assign block_guard_valid=valid;
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer i;
        begin
            c=previous^{24'd0,octet};
            for(i=0;i<8;i=i+1)
                c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction
    function [7:0] sector_byte;
        input [2:0] sector;
        input [8:0] address;
        input copy;
        input [31:0] content_crc;
        reg [31:0] final_crc;
        begin
            final_crc=~content_crc;
            sector_byte=0;
            if(sector==0) begin
                case(address)
                    0:sector_byte=8'h50; 1:sector_byte=8'h53;
                    2:sector_byte=8'h44; 3:sector_byte=8'h4c;
                    4:sector_byte=1;
                    8:sector_byte=copy ? 2 : 1;
                    default:sector_byte=0;
                endcase
            end else if(sector==7) begin
                case(address)
                    0:sector_byte=8'h50; 1:sector_byte=8'h53;
                    2:sector_byte=8'h44; 3:sector_byte=8'h43;
                    4:sector_byte=copy ? 2 : 1;
                    8:sector_byte=final_crc[7:0];
                    9:sector_byte=final_crc[15:8];
                    10:sector_byte=final_crc[23:16];
                    11:sector_byte=final_crc[31:24];
                    12:sector_byte=~final_crc[7:0];
                    13:sector_byte=~final_crc[15:8];
                    14:sector_byte=~final_crc[23:16];
                    15:sector_byte=~final_crc[31:24];
                    default:sector_byte=0;
                endcase
            end
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=S_IDLE; copy_b<=0; sector_index<=0; fill_index<=0;
            crc<=32'hffffffff; block_start<=0; buffer_we<=0;
            buffer_addr<=0; buffer_wdata<=0; done<=0; failed<=0;
        end else begin
            block_start<=0; buffer_we<=0; done<=0;
            case(state)
                S_IDLE: if(start) begin
                    copy_b<=0; sector_index<=0; fill_index<=0;
                    crc<=32'hffffffff; failed<=0; state<=S_FILL;
                end
                S_FILL: if(block_ready) begin
                    buffer_we<=1; buffer_addr<=fill_index;
                    buffer_wdata<=sector_byte(sector_index,fill_index,copy_b,crc);
                    if(sector_index!=7)
                        crc<=crc_byte(crc,sector_byte(sector_index,fill_index,copy_b,crc));
                    if(fill_index==9'd511) state<=S_REQUEST;
                    else fill_index<=fill_index+1'b1;
                end
                S_REQUEST: begin
                    if(!block_ready || !valid) begin failed<=1; state<=S_FAILED; end
                    else begin block_start<=1; state<=S_WAIT; end
                end
                S_WAIT: if(block_done) begin
                    if(block_error!=0) begin failed<=1; state<=S_FAILED; end
                    else state<=S_ADVANCE;
                end
                S_ADVANCE: begin
                    if(sector_index==7) begin
                        if(copy_b) state<=S_DONE;
                        else begin
                            copy_b<=1; sector_index<=0; fill_index<=0;
                            crc<=32'hffffffff; state<=S_FILL;
                        end
                    end else begin
                        sector_index<=sector_index+1'b1;
                        fill_index<=0; state<=S_FILL;
                    end
                end
                S_DONE: begin done<=1; state<=S_IDLE; end
                S_FAILED: begin done<=1; state<=S_IDLE; end
                default:state<=S_IDLE;
            endcase
        end
    end
endmodule
