`timescale 1ns/1ps
module tb_sd_score_page_real;
    reg clk=0, rst_n=0, start=0, block_done=0;
    reg pixel_clk=0, pixel_rst_n=0, de=1;
    always #5 clk=~clk;
    always #7 pixel_clk=~pixel_clk;
    wire block_start, block_write, block_guard_valid;
    wire [31:0] block_lba;
    wire [8:0] buffer_addr;
    wire bitmap_byte_valid, done, found, io_failed, invalid_spec;
    wire [15:0] bitmap_byte_index;
    wire [7:0] bitmap_byte;
    reg [7:0] fixture[0:1223019];
    reg [31:0] test_total, bitmap_offset;
    reg [1:0] test_notation;
    reg [5:0] test_page_index;
    wire [5:0] selected_page_index;
    reg [1023:0] file_path;
    wire [31:0] file_pos=((block_lba-32'd32768)<<9)+buffer_addr;
    wire [7:0] buffer_rdata=fixture[file_pos];
    integer fd, n, bytes=0, nonzero=0, cycles=0;
    integer x, y, visible_ink=0, checked_ink=0;
    reg [9:0] pix_x=0,pix_y=0;
    wire [15:0] page_addr;
    wire [7:0] pixel_byte;
    wire ready_video;
    wire [23:0] rgb;
    integer expected_bit;

    score_page_cache cache (
        .sys_clk(clk),.sys_rst_n(rst_n),.begin_load(start),
        .byte_valid(bitmap_byte_valid),.read_done(done),
        .read_available(found && !io_failed && !invalid_spec),
        .byte_index(bitmap_byte_index),.byte_value(bitmap_byte),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),
        .pixel_byte_addr(page_addr),.pixel_byte(pixel_byte),
        .ready_video(ready_video)
    );
    score_page_video video (
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),
        .de(de),.pix_x(pix_x),.pix_y(pix_y),
        .page_ready(ready_video),.page_byte(pixel_byte),
        .page_addr(page_addr),.rgb(rgb)
    );
    task check_pixel;
        input [9:0] x,y;
        reg [15:0] address;
        reg [10:0] source_x;
        begin
            @(negedge pixel_clk);
            pix_x=x;pix_y=y;
            source_x=(x*3)>>1;
            address=y*80+(x>>3);
            repeat(2) @(negedge pixel_clk);
            expected_bit=(fixture[bitmap_offset+y*120+(source_x>>3)] >>
                          (7-(source_x & 7))) & 1;
            if(page_addr!==address ||
               rgb!==(expected_bit ? 24'h101828 : 24'hF8FAFC))
                $fatal(1,"pixel (%0d,%0d): addr=%0d byte=%02x rgb=%h bit=%0d",
                    x,y,page_addr,pixel_byte,rgb,expected_bit);
        end
    endtask

    sd_score_page_read dut (
        .clk(clk),.rst_n(rst_n),.start(start),.slot(3'd0),
        .notation(test_notation),.page_index(test_page_index),
        .total_bytes(test_total),
        .sector_count(32'd100000),.block_ready(1'b1),
        .block_done(block_done),.block_error(8'd0),
        .buffer_rdata(buffer_rdata),.block_start(block_start),
        .block_write(block_write),.block_lba(block_lba),
        .block_guard_valid(block_guard_valid),.buffer_addr(buffer_addr),
        .bitmap_byte_valid(bitmap_byte_valid),
        .bitmap_byte_index(bitmap_byte_index),.bitmap_byte(bitmap_byte),
        .done(done),.found(found),.io_failed(io_failed),
        .invalid_spec(invalid_spec),
        .selected_page_index(selected_page_index)
    );
    always @(posedge clk) begin
        block_done<=block_start;
        if(rst_n) begin
            if(block_start && (block_write || !block_guard_valid))
                $fatal(1,"bad SD request");
            if(bitmap_byte_valid) begin
                if(bitmap_byte_index!==bytes ||
                   bitmap_byte!==fixture[bitmap_offset+bytes])
                    $fatal(1,"byte %0d mismatch",bytes);
                bytes=bytes+1;
                if(bitmap_byte!=0) nonzero=nonzero+1;
            end
            cycles=cycles+1;
            if(cycles>900000) $fatal(1,"timeout");
        end
    end
    initial begin
        if(!$value$plusargs("FILE=%s",file_path)) $fatal(1,"missing FILE");
        if(!$value$plusargs("TOTAL=%d",test_total)) $fatal(1,"missing TOTAL");
        if(!$value$plusargs("BITMAP=%d",bitmap_offset)) $fatal(1,"missing BITMAP");
        if(!$value$plusargs("NOTATION=%d",test_notation))
            $fatal(1,"missing NOTATION");
        if(!$value$plusargs("INDEX=%d",test_page_index))
            test_page_index=0;
        fd=$fopen(file_path,"rb");
        if(fd==0) $fatal(1,"cannot open %s",file_path);
        n=$fread(fixture,fd);
        $fclose(fd);
        if(n!=test_total) $fatal(1,"file size %0d expected %0d",n,test_total);
        repeat(3) @(negedge clk);
        rst_n=1;pixel_rst_n=1;
        @(negedge clk) start=1;
        @(negedge clk) start=0;
        repeat(4) @(negedge pixel_clk);
        if(ready_video || rgb!==24'h14213D)
            $fatal(1,"incomplete page exposed");
        wait(done);
        @(negedge clk);
        if(!found || io_failed || invalid_spec || bytes!=57600 || nonzero==0 ||
           selected_page_index!==
             (test_page_index>(test_notation==1 ? 6 : 5) ? 6'd0 : test_page_index))
            $fatal(1,"page failed found=%b io=%b spec=%b bytes=%0d nonzero=%0d",
                found,io_failed,invalid_spec,bytes,nonzero);
        repeat(4) @(negedge pixel_clk);
        if(!ready_video) $fatal(1,"complete page not published");
        check_pixel(0,0);
        check_pixel(320,240);
        check_pixel(639,479);
        for(y=0;y<480;y=y+1)
            for(x=0;x<640;x=x+1)
                if((fixture[bitmap_offset+y*120+((x*3)>>4)] >>
                    (7-(((x*3)>>1)&7)))&1) begin
                    visible_ink=visible_ink+1;
                    if(checked_ink<3) begin
                        check_pixel(x,y);
                        checked_ink=checked_ink+1;
                    end
                end
        if(visible_ink==0) $fatal(1,"no visible ink in real page");
        $display("PASS real PSC2 notation %0d through reader/cache/video: %0d bytes, %0d nonzero, %0d visible ink, %0d cycles",
            test_notation,bytes,nonzero,visible_ink,cycles);
        $finish;
    end
endmodule
