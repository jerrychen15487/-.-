`timescale 1ns/1ps
module tb_sd_diag_clear_top;
    reg clk=0,rst_n=0,key_n=1;
    always #10 clk=~clk;
    wire cs_n,sck,mosi;
    wire [2:0] dp,dn;
    wire cp,cn;
    top_sd_diag_clear_test dut(clk,rst_n,key_n,1'b1,
        cs_n,sck,mosi,dp,dn,cp,cn);
    integer i,j,timeout;
    reg [31:0] crc;
    task build_a3;
        begin
            for(i=0;i<4096;i=i+1) dut.card.directory_mem[i]=0;
            dut.card.directory_mem[0]="P";
            dut.card.directory_mem[1]="S";
            dut.card.directory_mem[2]="D";
            dut.card.directory_mem[3]="L";
            dut.card.directory_mem[4]=1;
            dut.card.directory_mem[8]=3;
            dut.card.directory_mem[12]=1;
            for(i=0;i<16;i=i+1)
                dut.card.directory_mem[16+i]=
                    (128'h54414e472d444941472d53434f524530 >> (120-8*i));
            dut.card.directory_mem[32]=1;
            dut.card.directory_mem[34]=4;
            dut.card.directory_mem[37]=2;
            dut.card.directory_mem[40]=8'h1f;
            dut.card.directory_mem[41]=8'h93;
            dut.card.directory_mem[42]=8'hcd;
            dut.card.directory_mem[43]=8'h67;
            dut.card.directory_mem[48]=1;
            dut.card.directory_mem[53]=2;
            dut.card.directory_mem[54]=2;
            dut.card.directory_mem[56]=3;
            dut.card.directory_mem[64]="D";
            dut.card.directory_mem[65]="I";
            dut.card.directory_mem[66]="A";
            dut.card.directory_mem[67]="G";
            crc=32'hffffffff;
            for(i=0;i<3584;i=i+1)
                crc=dut.card.crc_byte(crc,dut.card.directory_mem[i]);
            crc=~crc;
            dut.card.directory_mem[3584]="P";
            dut.card.directory_mem[3585]="S";
            dut.card.directory_mem[3586]="D";
            dut.card.directory_mem[3587]="C";
            dut.card.directory_mem[3588]=3;
            for(i=0;i<4;i=i+1) begin
                dut.card.directory_mem[3592+i]=crc[8*i +: 8];
                dut.card.directory_mem[3596+i]=~crc[8*i +: 8];
            end
        end
    endtask
    task reset_fpga;
        begin
            @(negedge clk); rst_n=0;
            repeat(4) @(negedge clk); rst_n=1;
        end
    endtask
    task wait_status;
        input [15:0] expected;
        begin
            timeout=0;
            while(dut.status!=expected && timeout<120000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(dut.status!=expected)
                $fatal(1,"status=%h expected=%h",dut.status,expected);
        end
    endtask
    initial begin
        #1; build_a3();
        // A valid CRC alone is insufficient if the UUID is not DIAG.
        dut.card.directory_mem[16]="X";
        crc=32'hffffffff;
        for(j=0;j<3584;j=j+1)
            crc=dut.card.crc_byte(crc,dut.card.directory_mem[j]);
        crc=~crc;
        for(j=0;j<4;j=j+1) begin
            dut.card.directory_mem[3592+j]=crc[8*j +: 8];
            dut.card.directory_mem[3596+j]=~crc[8*j +: 8];
        end
        repeat(4) @(negedge clk); rst_n=1;
        wait_status(16'hE095);
        force dut.key_pulse=1;
        @(negedge clk); release dut.key_pulse;
        if(dut.card.writes!=0) $fatal(1,"foreign card written");
        build_a3(); reset_fpga();
        wait_status(16'hD301);
        // A3 alone is not enough: B2 must be a valid rollback copy.
        dut.card.directory_mem[4096+3584]=0;
        reset_fpga(); wait_status(16'hE095);
        force dut.key_pulse=1;
        @(negedge clk); release dut.key_pulse;
        if(dut.card.writes!=0) $fatal(1,"sole-copy card written");
        dut.card.directory_mem[4096+3584]="P";
        reset_fpga(); wait_status(16'hD301);
        if(dut.card.writes!=0) $fatal(1,"auto-wrote on boot");
        force dut.key_pulse=1;
        @(negedge clk); release dut.key_pulse;
        wait_status(16'hD400);
        if(dut.card.writes!=8 || dut.card.directory_mem[3588]!=3 ||
           dut.card.directory_mem[4096+3588]!=4)
            $fatal(1,"clear did not preserve A3 and publish B4");
        reset_fpga(); wait_status(16'hD400);
        if(dut.card.writes!=8) $fatal(1,"reboot wrote card");
        force dut.key_pulse=1;
        @(negedge clk); release dut.key_pulse;
        repeat(20) @(negedge clk);
        if(dut.card.writes!=8) $fatal(1,"repeat key wrote empty card");
        $display("PASS sd_diag_clear_top foreign/rollback-guard/explicit-B4/reboot/idempotent");
        $finish;
    end
endmodule

module sd_spi_block_device (
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
    reg [7:0] directory_mem[0:8191],scratch[0:511];
    integer writes=0,pending=0,i,copy_id,j,base;
    reg [31:0] crc;
    assign ready=1;
    assign init_done=1;
    assign error_code=0;
    assign sector_count=100000;
    assign cs_n=1; assign sck=0; assign mosi=1;
    assign buffer_rdata=scratch[buffer_addr];
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] x;
        integer k;
        begin
            x=previous^{24'd0,octet};
            for(k=0;k<8;k=k+1)
                x=x[0] ? ((x>>1)^32'hedb88320) : (x>>1);
            crc_byte=x;
        end
    endfunction
    initial begin
        for(i=0;i<8192;i=i+1) directory_mem[i]=0;
        for(i=0;i<512;i=i+1) scratch[i]=0;
        // B2 empty rollback copy.
        base=4096;
        directory_mem[base+0]="P";
        directory_mem[base+1]="S";
        directory_mem[base+2]="D";
        directory_mem[base+3]="L";
        directory_mem[base+4]=1;
        directory_mem[base+8]=2;
        crc=32'hffffffff;
        for(j=0;j<3584;j=j+1)
            crc=crc_byte(crc,directory_mem[base+j]);
        crc=~crc;
        directory_mem[base+3584]="P";
        directory_mem[base+3585]="S";
        directory_mem[base+3586]="D";
        directory_mem[base+3587]="C";
        directory_mem[base+3588]=2;
        for(j=0;j<4;j=j+1) begin
            directory_mem[base+3592+j]=crc[8*j +: 8];
            directory_mem[base+3596+j]=~crc[8*j +: 8];
        end
    end
    always @(posedge clk) begin
        done<=0;
        if(rst_n) begin
            if(buffer_we && !req_start) scratch[buffer_addr]=buffer_wdata;
            if(req_start) begin
                if(!req_guard_valid || req_lba<16384 || req_lba>16399)
                    $fatal(1,"unsafe LBA %0d",req_lba);
                if(req_write) begin
                    if(req_lba<16392) $fatal(1,"A3 rollback overwritten");
                    for(i=0;i<512;i=i+1)
                        directory_mem[(req_lba-16384)*512+i]=scratch[i];
                    writes=writes+1;
                end else
                    for(i=0;i<512;i=i+1)
                        scratch[i]=directory_mem[(req_lba-16384)*512+i];
                pending=3;
            end else if(pending>0) begin
                pending=pending-1;
                if(pending==0) done<=1;
            end
        end
    end
endmodule

module sd_hex_display (
    input wire sys_clk,rst_n,input wire [15:0] status,
    input wire [31:0] row1,row2,row3,
    output wire [2:0] tmds_d_p_0,tmds_d_n_0,
    output wire tmds_clk_p_0,tmds_clk_n_0
);
    assign tmds_d_p_0=0; assign tmds_d_n_0=0;
    assign tmds_clk_p_0=0; assign tmds_clk_n_0=0;
endmodule
