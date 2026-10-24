`timescale 1ns/1ps
module tb_sd_block_test_control;
    reg clk=0, rst_n=0, key_n=1;
    always #10 clk=~clk;
    wire cs_n,sck,mosi;
    wire [2:0] dp,dn;
    wire cp,cn;
    top_sd_block_test dut(clk,rst_n,key_n,1'b1,cs_n,sck,mosi,dp,dn,cp,cn);
    integer timeout;
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        repeat(1500) @(negedge clk);
        if(dut.card.request_count!=0 || dut.status!=16'hD100)
            $fatal(1,"diagnostic wrote without KEY1");
        force dut.key_pulse=1'b1;
        @(negedge clk); release dut.key_pulse;
        timeout=0;
        while(dut.status!=16'hD124 && timeout<3000) begin
            @(negedge clk); timeout=timeout+1;
        end
        if(dut.status!=16'hD124 || dut.card.request_count!=3)
            $fatal(1,"three-sector test failed status=%h count=%0d",dut.status,dut.card.request_count);
        repeat(200) @(negedge clk);
        if(dut.card.request_count!=3) $fatal(1,"test unexpectedly repeated");
        $display("PASS sd_block_test_control no-auto-write/three guarded writes/one-shot");
        $finish;
    end
endmodule

module sd_spi_block_device(
    input wire clk,rst_n,miso,
    output wire cs_n,sck,mosi,
    input wire req_start,req_write,req_guard_valid,
    input wire [31:0] req_lba,
    output wire ready,init_done,
    output reg done,
    output wire [7:0] error_code,
    output wire [31:0] sector_count,
    input wire [8:0] buffer_addr,
    input wire [7:0] buffer_wdata,
    input wire buffer_we,
    output wire [7:0] buffer_rdata
);
    reg [7:0] mem[0:511];
    integer request_count=0,wait_cycles=0,i;
    assign ready=1'b1;
    assign init_done=1'b1;
    assign sector_count=32'd32768;
    assign error_code=0;
    assign buffer_rdata=mem[buffer_addr];
    assign cs_n=1'b1;
    assign sck=1'b0;
    assign mosi=1'b1;
    always @(posedge clk) begin
        if(!rst_n) begin done<=0; request_count=0; wait_cycles=0; end
        else begin
            done<=0;
            if(buffer_we && !req_start) mem[buffer_addr]<=buffer_wdata;
            if(req_start) begin
                if(!req_write || !req_guard_valid || req_lba!=32'd8193+request_count)
                    $fatal(1,"wrong request lba=%0d count=%0d",req_lba,request_count);
                for(i=0;i<512;i=i+1)
                    if(mem[i] !== (i[7:0] ^ request_count[7:0] ^ 8'hA5))
                        $fatal(1,"buffer mismatch at %0d sector %0d got %h",i,request_count,mem[i]);
                request_count=request_count+1; wait_cycles=4;
            end
            if(wait_cycles>0) begin
                wait_cycles=wait_cycles-1;
                if(wait_cycles==0) done<=1;
            end
        end
    end
endmodule
module video_pll(input wire clk_in,reset,output wire pixel_clk,serial_clk,locked);
    assign pixel_clk=clk_in; assign serial_clk=clk_in; assign locked=!reset;
endmodule
module video_timing_640x480(input wire pixel_clk,rst_n,output wire hsync,vsync,de,
    output wire [9:0] pix_x,pix_y);
    assign hsync=0; assign vsync=0; assign de=0; assign pix_x=0; assign pix_y=0;
endmodule
module dvi_tmds_encoder(input wire pixel_clk,rst_n,de,input wire [7:0] data,
    input wire c0,c1,output wire [9:0] tmds);
    assign tmds=0;
endmodule
module dvi_tmds_lane(input wire pixel_clk,serial_clk,rst_n,input wire [9:0] symbol,
    output wire out_p,out_n);
    assign out_p=0; assign out_n=1;
endmodule
module dvi_clock_lane(input wire pixel_clk,output wire out_p,out_n);
    assign out_p=0; assign out_n=1;
endmodule
