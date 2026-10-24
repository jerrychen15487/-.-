// Cache the 3584 CRC-covered bytes of a directory copy already selected by
// sd_directory_mount. Mutations are explicit; this module never writes SD.
module sd_directory_image (
    input wire clk,rst_n,start,directory_b,
    input wire [31:0] sector_count,
    input wire block_ready,block_done,
    input wire [7:0] block_error,
    output reg block_start,
    output wire [31:0] block_lba,
    output wire block_guard_valid,
    output wire [8:0] buffer_addr,
    input wire [7:0] buffer_rdata,
    input wire [11:0] read_addr,
    output reg [7:0] read_byte,
    input wire write_enable,
    input wire [11:0] write_addr,
    input wire [7:0] write_byte,
    output reg done,io_failed
);
    localparam IDLE=0,REQUEST=1,WAIT_BLOCK=2,COPY=3,FINISH=4;
    reg [2:0] state,sector_index;
    reg [8:0] byte_index;
    reg held_b;
    wire [31:0] lba;
    wire lba_valid;
    reg [7:0] image_mem[0:3583];
    assign buffer_addr=byte_index;
    // Registered read lets Gowin map the 3.5 KiB directory image to BSRAM.
    // Callers issue the address one clock before consuming read_byte.
    assign block_lba=lba;
    assign block_guard_valid=lba_valid;
    sd_storage_lba address_guard (
        .region(2'd0),.directory_b(held_b),.slot(3'd0),
        .index({10'd0,sector_index}),.sector_count(sector_count),
        .lba(lba),.valid(lba_valid)
    );
    always @(posedge clk) begin
        read_byte <= (read_addr<12'd3584) ? image_mem[read_addr] : 8'd0;
        if(write_enable && write_addr>=12'd16 && write_addr<12'd3584)
            image_mem[write_addr]<=write_byte;
        else if(state==COPY)
            image_mem[{sector_index,byte_index}]<=buffer_rdata;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; sector_index<=0; byte_index<=0;
            held_b<=0; block_start<=0; done<=0; io_failed<=0;
        end else begin
            block_start<=0; done<=0;
            case(state)
                IDLE: if(start) begin
                    held_b<=directory_b; sector_index<=0;
                    byte_index<=0; io_failed<=0; state<=REQUEST;
                end
                REQUEST: if(block_ready) begin
                    if(!lba_valid) begin io_failed<=1; state<=FINISH; end
                    else begin block_start<=1; state<=WAIT_BLOCK; end
                end
                WAIT_BLOCK: if(block_done) begin
                    if(block_error!=0) begin io_failed<=1; state<=FINISH; end
                    else begin byte_index<=0; state<=COPY; end
                end
                COPY: if(byte_index==9'd511) begin
                    if(sector_index==3'd6) state<=FINISH;
                    else begin sector_index<=sector_index+1'b1; state<=REQUEST; end
                end else byte_index<=byte_index+1'b1;
                FINISH: begin done<=1; state<=IDLE; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
