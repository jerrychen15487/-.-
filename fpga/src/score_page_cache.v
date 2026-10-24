// Pack the 640 columns selected by the HDMI downsampler from each 960x480
// MONO1 page. All 57,600 source bytes must still arrive in order before the
// 38,400-byte display image is published. The RAM has no reset.
module score_page_cache (
    input wire sys_clk,sys_rst_n,
    input wire begin_load,byte_valid,read_done,read_available,
    input wire [15:0] byte_index,
    input wire [7:0] byte_value,
    input wire pixel_clk,pixel_rst_n,
    input wire [15:0] pixel_byte_addr,
    output reg [7:0] pixel_byte,
    output wire ready_video
);
    reg [7:0] page_mem[0:38399];
    reg [15:0] next_index;
    reg [15:0] packed_index;
    reg [1:0] source_phase;
    reg [7:0] source_byte0,source_byte1;
    reg order_bad,ready_sys;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ready_sync;
    assign ready_video=ready_sync[1];
    always @(posedge sys_clk)
        if(sys_rst_n && !begin_load && byte_valid &&
           byte_index==next_index && next_index<16'd57600 &&
           source_phase!=0)
            page_mem[packed_index]<=source_phase==1 ?
                {source_byte0[7:6],source_byte0[4:3],source_byte0[1:0],byte_value[6:5]} :
                {source_byte1[3:2],source_byte1[0],byte_value[7],
                 byte_value[5:4],byte_value[2:1]};
    always @(posedge pixel_clk)
        pixel_byte<=page_mem[pixel_byte_addr];
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            next_index<=0;packed_index<=0;source_phase<=0;
            source_byte0<=0;source_byte1<=0;
            order_bad<=0;ready_sys<=0;
        end else if(begin_load) begin
            next_index<=0;packed_index<=0;source_phase<=0;
            order_bad<=0;ready_sys<=0;
        end else begin
            if(byte_valid) begin
                if(byte_index!=next_index || next_index>=16'd57600)
                    order_bad<=1;
                else begin
                    next_index<=next_index+1'b1;
                    if(source_phase==0) begin
                        source_byte0<=byte_value;
                        source_phase<=1;
                    end else if(source_phase==1) begin
                        source_byte1<=byte_value;
                        source_phase<=2;
                        packed_index<=packed_index+1'b1;
                    end else begin
                        source_phase<=0;
                        packed_index<=packed_index+1'b1;
                    end
                end
            end
            if(read_done)
                ready_sys<=read_available && !order_bad &&
                    next_index==16'd57600 && packed_index==16'd38400 &&
                    source_phase==0;
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            ready_sync<=0;
        end else begin
            ready_sync<={ready_sync[0],ready_sys};
        end
    end
endmodule
