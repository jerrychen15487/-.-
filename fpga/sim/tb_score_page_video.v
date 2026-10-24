`timescale 1ns/1ps
module tb_score_page_video;
    reg pixel_clk=0;
    always #5 pixel_clk=~pixel_clk;
    reg pixel_rst_n=0,de=1,page_ready=1;
    reg [9:0] pix_x=0,pix_y=0;
    reg [7:0] page_byte=8'h80;
    wire [15:0] page_addr;
    wire [23:0] rgb;
    score_page_video dut(
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),
        .de(de),.pix_x(pix_x),.pix_y(pix_y),
        .page_ready(page_ready),.page_byte(page_byte),
        .page_addr(page_addr),.rgb(rgb)
    );
    initial begin
        repeat(2) @(negedge pixel_clk);
        pixel_rst_n=1;
        @(negedge pixel_clk);
        if(page_addr!==0 || rgb!==24'h101828)
            $fatal(1,"top-left pixel wrong addr=%0d rgb=%h",page_addr,rgb);
        pix_x=1;
        @(negedge pixel_clk);
        if(page_addr!==0 || rgb!==24'hF8FAFC)
            $fatal(1,"horizontal bit selection wrong");
        pix_x=639;pix_y=479;page_byte=8'h01;
        @(negedge pixel_clk);
        if(page_addr!==16'd38399 || rgb!==24'h101828)
            $fatal(1,"bottom-right pixel wrong addr=%0d rgb=%h",page_addr,rgb);
        page_ready=0;
        #1;
        if(rgb!==24'h14213D) $fatal(1,"unready page visible");
        $display("PASS score_page_video: geometry, bit order and hidden-until-ready");
        $finish;
    end
endmodule
