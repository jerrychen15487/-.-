`timescale 1ns/1ps
module tb_sd_score_recovery_top;
    reg clk=0,rst_n=0,key_n=1;
    always #10 clk=~clk;
    wire cs_n,sck,mosi;
    wire [2:0] dp,dn;
    wire cp,cn;
    top_sd_score_recovery_test dut(clk,rst_n,key_n,1'b1,
        cs_n,sck,mosi,dp,dn,cp,cn);
    integer timeout;
    integer k;
    reg [31:0] check_crc;
    task press_key;
        begin
            force dut.key_pulse=1'b1;
            @(negedge clk); release dut.key_pulse;
        end
    endtask
    task restart_fpga;
        begin
            @(negedge clk); rst_n=0;
            repeat(4) @(negedge clk); rst_n=1;
        end
    endtask
    task recalc_a_commit;
        begin
            check_crc=32'hffffffff;
            for(k=0;k<3584;k=k+1)
                check_crc=dut.card.crc_byte(check_crc,dut.card.directory_mem[k]);
            check_crc=~check_crc;
            for(k=0;k<4;k=k+1) begin
                dut.card.directory_mem[3592+k]=check_crc[8*k +: 8];
                dut.card.directory_mem[3596+k]=~check_crc[8*k +: 8];
            end
        end
    endtask
    task wait_status;
        input [15:0] expected;
        begin
            timeout=0;
            while(dut.status!=expected && timeout<100000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(dut.status!=expected)
                $fatal(1,"status timeout got=%h expected=%h",dut.status,expected);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait_status(16'hD202);
        if(dut.card.writes!=0) $fatal(1,"auto-wrote on boot");
        press_key;
        wait_status(16'hD301);
        if(dut.card.writes!=10)
            $fatal(1,"expected 8 directory + 2 block writes; got %0d",dut.card.writes);
        if(dut.generation!=3 || dut.entry_count!=1 || dut.next_block!=1)
            $fatal(1,"diagnostic recovery wrong");
        // Pressing again after success never repeats or erases anything.
        press_key;
        repeat(20) @(negedge clk);
        if(dut.card.writes!=10) $fatal(1,"completed entry overwritten");
        // Power loss preserves the card but clears all FPGA registers.
        restart_fpga;
        wait_status(16'hD301);
        if(dut.card.writes!=10) $fatal(1,"reboot wrote to card");
        dut.card.song_mem[512+24]=dut.card.song_mem[512+24]^8'h01;
        restart_fpga;
        wait_status(16'hD300);
        if(dut.card.writes!=10) $fatal(1,"corrupt log auto-repaired");
        press_key;
        wait_status(16'hD301);
        if(dut.card.writes!=12) $fatal(1,"manual repair did not rewrite block");
        // Valid CRC and generation do not prove this is our diagnostic entry.
        dut.card.directory_mem[16]=8'h58;
        recalc_a_commit;
        restart_fpga;
        wait_status(16'hE095);
        press_key;
        repeat(20) @(negedge clk);
        if(dut.card.writes!=12) $fatal(1,"foreign A3 was overwritten");
        // A2 is the only valid copy. Never overwrite it to seed A3.
        for(k=0;k<4096;k=k+1)
            dut.card.directory_mem[k]=dut.card.directory_mem[4096+k];
        dut.card.directory_mem[4096+3584]=0;
        restart_fpga;
        wait_status(16'hE095);
        press_key;
        repeat(20) @(negedge clk);
        if(dut.card.writes!=12 || dut.card.directory_mem[8]!=2 ||
           dut.card.directory_mem[4096+3584]!=0)
            $fatal(1,"sole valid A2 copy was modified");
        $display("PASS sd_score_recovery_top write/remount/reset/repair/foreign-entry/sole-copy guards");
        $finish;
    end
endmodule

// Fake block device for this test only; card arrays survive FPGA reset.
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
    reg [7:0] directory_mem[0:8191],song_mem[0:1023],scratch[0:511];
    integer writes=0,reads=0,pending=0,i,copy_id,j,base;
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
        for(i=0;i<1024;i=i+1) song_mem[i]=0;
        for(i=0;i<512;i=i+1) scratch[i]=0;
        for(copy_id=0;copy_id<2;copy_id=copy_id+1) begin
            base=copy_id*4096;
            directory_mem[base+0]="P";
            directory_mem[base+1]="S";
            directory_mem[base+2]="D";
            directory_mem[base+3]="L";
            directory_mem[base+4]=1;
            directory_mem[base+8]=copy_id+1;
            crc=32'hffffffff;
            for(j=0;j<3584;j=j+1)
                crc=crc_byte(crc,directory_mem[base+j]);
            crc=~crc;
            directory_mem[base+3584]="P";
            directory_mem[base+3585]="S";
            directory_mem[base+3586]="D";
            directory_mem[base+3587]="C";
            directory_mem[base+3588]=copy_id+1;
            for(j=0;j<4;j=j+1) begin
                directory_mem[base+3592+j]=crc[8*j +: 8];
                directory_mem[base+3596+j]=~crc[8*j +: 8];
            end
        end
    end
    always @(posedge clk) begin
        done<=0;
        if(rst_n) begin
            if(buffer_we && !req_start) scratch[buffer_addr]=buffer_wdata;
            if(req_start) begin
                if(!req_guard_valid ||
                   !((req_lba>=16384 && req_lba<=16399) ||
                     req_lba==32768 || req_lba==36864))
                    $fatal(1,"unsafe LBA %0d",req_lba);
                if(req_write) begin
                    if(req_lba>=16384 && req_lba<=16399) begin
                        if(req_lba<16384 || req_lba>16391)
                            $fatal(1,"old directory B overwritten");
                        for(i=0;i<512;i=i+1)
                            directory_mem[(req_lba-16384)*512+i]=scratch[i];
                    end else if(req_lba==32768) begin
                        for(i=0;i<512;i=i+1) song_mem[i]=scratch[i];
                    end else begin
                        for(i=0;i<512;i=i+1) song_mem[512+i]=scratch[i];
                    end
                    writes=writes+1;
                end else begin
                    if(req_lba>=16384 && req_lba<=16399)
                        for(i=0;i<512;i=i+1)
                            scratch[i]=directory_mem[(req_lba-16384)*512+i];
                    else if(req_lba==32768)
                        for(i=0;i<512;i=i+1) scratch[i]=song_mem[i];
                    else for(i=0;i<512;i=i+1) scratch[i]=song_mem[512+i];
                    reads=reads+1;
                end
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
