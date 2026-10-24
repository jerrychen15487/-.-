`timescale 1ns/1ps
module tb_sd_directory_top;
    reg clk=0,rst_n=0,key_n=1;
    always #10 clk=~clk;
    wire cs_n,sck,mosi;
    wire [2:0] dp,dn;
    wire cp,cn;
    top_sd_directory_test dut(clk,rst_n,key_n,1'b1,cs_n,sck,mosi,dp,dn,cp,cn);
    integer timeout;
    task wait_status;
        input [15:0] expected;
        begin
            timeout=0;
            while(dut.status!=expected && timeout<40000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(dut.status!=expected)
                $fatal(1,"status timeout got=%h expected=%h",dut.status,expected);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait_status(16'hD000);
        if(dut.card.writes!=0) $fatal(1,"auto-initialized card");
        force dut.key_pulse=1'b1;
        @(negedge clk); release dut.key_pulse;
        wait_status(16'hD202);
        if(dut.card.writes!=16) $fatal(1,"expected 16 directory writes");
        force dut.key_pulse=1'b1;
        @(negedge clk); release dut.key_pulse;
        repeat(20) @(negedge clk);
        if(dut.card.writes!=16) $fatal(1,"mounted directory was overwritten");
        @(negedge clk); rst_n=0;
        repeat(4) @(negedge clk); rst_n=1;
        wait_status(16'hD202);
        if(dut.card.writes!=16) $fatal(1,"reset caused write");
        dut.card.card_mem[0]=8'h51;
        dut.card.card_mem[4096]=8'h51;
        @(negedge clk); rst_n=0;
        repeat(4) @(negedge clk); rst_n=1;
        wait_status(16'hE092);
        force dut.key_pulse=1'b1;
        @(negedge clk); release dut.key_pulse;
        repeat(20) @(negedge clk);
        if(dut.card.writes!=16) $fatal(1,"corrupt directory was overwritten");
        $display("PASS sd_directory_top blank/explicit-init/remount/reset/no-overwrite/corrupt-lockout");
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
    reg [7:0] card_mem[0:8191],scratch[0:511];
    reg [31:0] active_lba=16384;
    integer writes=0,reads=0,pending=0,i;
    assign ready=1;
    assign init_done=1;
    assign error_code=0;
    assign sector_count=32768;
    assign cs_n=1; assign sck=0; assign mosi=1;
    assign buffer_rdata=card_mem[(active_lba-16384)*512+buffer_addr];
    initial for(i=0;i<8192;i=i+1) card_mem[i]=0;
    always @(posedge clk) begin
        done<=0;
        if(rst_n) begin
            if(buffer_we && !req_start) scratch[buffer_addr]<=buffer_wdata;
            if(req_start) begin
                if(!req_guard_valid || req_lba<16384 || req_lba>16399)
                    $fatal(1,"unsafe LBA %0d",req_lba);
                active_lba<=req_lba;
                if(req_write) begin
                    for(i=0;i<512;i=i+1)
                        card_mem[(req_lba-16384)*512+i]=scratch[i];
                    writes=writes+1;
                end else reads=reads+1;
                pending=3;
            end else if(pending>0) begin
                pending=pending-1;
                if(pending==0) done<=1;
            end
        end
    end
endmodule
module sd_hex_display(
    input wire sys_clk,rst_n,input wire [15:0] status,
    input wire [31:0] row1,row2,row3,
    output wire [2:0] tmds_d_p_0,tmds_d_n_0,
    output wire tmds_clk_p_0,tmds_clk_n_0
);
    assign tmds_d_p_0=0; assign tmds_d_n_0=0;
    assign tmds_clk_p_0=0; assign tmds_clk_n_0=0;
endmodule
