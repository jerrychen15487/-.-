`timescale 1ns/1ps
module tb_score_page_cache;
    reg sys_clk=0,pixel_clk=0;
    always #5 sys_clk=~sys_clk;
    always #7 pixel_clk=~pixel_clk;
    reg sys_rst_n=0,pixel_rst_n=0;
    reg begin_load=0,byte_valid=0,read_done=0,read_available=0;
    reg [15:0] byte_index=0,pixel_byte_addr=0;
    reg [7:0] byte_value=0;
    wire [7:0] pixel_byte;
    wire ready_video;
    reg [7:0] fixture[0:231455];
    reg [1023:0] file_path;
    integer fd,n,i;
    function [7:0] packed_fixture_byte;
        input integer address;
        integer bit_index,source_x,source_addr;
        begin
            packed_fixture_byte=0;
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                source_x=(((address%80)*8+bit_index)*3)>>1;
                source_addr=880+(address/80)*120+(source_x>>3);
                packed_fixture_byte[7-bit_index]=
                    fixture[source_addr][7-(source_x&7)];
            end
        end
    endfunction
    score_page_cache dut(
        .sys_clk(sys_clk),.sys_rst_n(sys_rst_n),
        .begin_load(begin_load),.byte_valid(byte_valid),
        .read_done(read_done),.read_available(read_available),
        .byte_index(byte_index),.byte_value(byte_value),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),
        .pixel_byte_addr(pixel_byte_addr),.pixel_byte(pixel_byte),
        .ready_video(ready_video)
    );
    task check_pixel_byte;
        input [15:0] address;
        input [7:0] expected;
        begin
            @(negedge pixel_clk);pixel_byte_addr=address;
            @(negedge pixel_clk);
            if(pixel_byte!==expected)
                $fatal(1,"cache mismatch at %0d: got %02x expected %02x",
                    address,pixel_byte,expected);
        end
    endtask
    initial begin
        if(!$value$plusargs("FILE=%s",file_path))
            $fatal(1,"pass +FILE=sim/engineering_test.pseq");
        fd=$fopen(file_path,"rb");
        if(fd==0) $fatal(1,"cannot open %s",file_path);
        n=$fread(fixture,fd);
        $fclose(fd);
        if(n!=231456) $fatal(1,"fixture size %0d",n);
        repeat(3) @(negedge sys_clk);
        sys_rst_n=1;pixel_rst_n=1;
        begin_load=1;
        @(negedge sys_clk);begin_load=0;
        for(i=0;i<57600;i=i+1) begin
            byte_valid=1;byte_index=i;byte_value=fixture[880+i];
            @(negedge sys_clk);
        end
        byte_valid=0;read_available=1;read_done=1;
        @(negedge sys_clk);read_done=0;
        repeat(4) @(negedge pixel_clk);
        if(!ready_video) $fatal(1,"complete page not published");
        for(i=0;i<38400;i=i+1)
            check_pixel_byte(i,packed_fixture_byte(i));
        @(negedge sys_clk);begin_load=1;
        @(negedge sys_clk);begin_load=0;
        repeat(4) @(negedge pixel_clk);
        if(ready_video) $fatal(1,"stale page remains visible during reload");
        byte_valid=1;byte_index=1;byte_value=8'hff;
        @(negedge sys_clk);byte_valid=0;read_done=1;
        @(negedge sys_clk);read_done=0;
        repeat(4) @(negedge pixel_clk);
        if(ready_video) $fatal(1,"out-of-order page published");
        $display("PASS score_page_cache: all 38400 packed bytes, reload and order guard");
        $finish;
    end
endmodule
