`timescale 1ns/1ps
module tb_sd_directory_mount;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    wire block_start,block_guard_valid,done,mounted,io_error,blank_media;
    wire [31:0] block_lba,generation;
    wire [8:0] buffer_addr;
    wire [2:0] entry_count;
    wire a_valid,b_valid;
    wire [31:0] a_generation,b_generation;
    wire [2:0] a_entry_count,b_entry_count;
    reg block_done=0;
    reg [7:0] block_error=0;
    reg [7:0] card_mem[0:8191];
    reg [31:0] active_lba=16384;
    reg [2:0] pending=0;
    reg inject_io=0;
    wire [7:0] buffer_rdata=card_mem[(active_lba-32'd16384)*512+buffer_addr];
    sd_directory_mount dut(clk,rst_n,start,1'b1,block_done,block_error,
        32'd32768,block_start,block_lba,block_guard_valid,buffer_addr,
        buffer_rdata,done,mounted,io_error,blank_media,generation,entry_count,
        a_valid,b_valid,a_generation,b_generation,a_entry_count,b_entry_count);
    always @(posedge clk) begin
        block_done<=0;
        if(!rst_n) pending<=0;
        else if(block_start) begin
            if(!block_guard_valid || block_lba<16384 || block_lba>16399)
                $fatal(1,"directory LBA guard failed: %0d",block_lba);
            active_lba<=block_lba; pending<=3;
        end else if(pending!=0) begin
            pending<=pending-1'b1;
            if(pending==1) begin
                block_error<=inject_io && active_lba==16384 ? 8'h31 : 0;
                block_done<=1;
            end
        end
    end
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer k;
        begin
            c=previous^{24'd0,octet};
            for(k=0;k<8;k=k+1)
                c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction
    integer i;
    reg [31:0] c;
    task blank;
        begin for(i=0;i<8192;i=i+1) card_mem[i]=0; end
    endtask
    task make_copy;
        input integer copy;
        input [31:0] gen;
        input [7:0] count;
        integer base,j;
        begin
            base=copy*4096;
            card_mem[base+0]=8'h50; card_mem[base+1]=8'h53;
            card_mem[base+2]=8'h44; card_mem[base+3]=8'h4c;
            card_mem[base+4]=1;
            card_mem[base+8]=gen[7:0]; card_mem[base+9]=gen[15:8];
            card_mem[base+10]=gen[23:16]; card_mem[base+11]=gen[31:24];
            card_mem[base+12]=count;
            c=32'hffffffff;
            for(j=0;j<3584;j=j+1) c=crc_byte(c,card_mem[base+j]);
            c=~c;
            card_mem[base+3584]=8'h50; card_mem[base+3585]=8'h53;
            card_mem[base+3586]=8'h44; card_mem[base+3587]=8'h43;
            card_mem[base+3588]=gen[7:0]; card_mem[base+3589]=gen[15:8];
            card_mem[base+3590]=gen[23:16]; card_mem[base+3591]=gen[31:24];
            card_mem[base+3592]=c[7:0]; card_mem[base+3593]=c[15:8];
            card_mem[base+3594]=c[23:16]; card_mem[base+3595]=c[31:24];
            card_mem[base+3596]=~c[7:0]; card_mem[base+3597]=~c[15:8];
            card_mem[base+3598]=~c[23:16]; card_mem[base+3599]=~c[31:24];
        end
    endtask
    task run_mount;
        integer timeout;
        begin
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            timeout=0;
            while(!done && timeout<30000) begin @(negedge clk); timeout=timeout+1; end
            if(!done) $fatal(1,"mount timeout state=%0d",dut.state);
            @(negedge clk);
        end
    endtask
    initial begin
        blank(); repeat(3) @(negedge clk); rst_n=1;
        run_mount();
        if(mounted || generation!=0 || !blank_media) $fatal(1,"blank card mounted");
        make_copy(0,32'd2,1);
        run_mount();
        if(!mounted || blank_media || generation!=2 || entry_count!=1) $fatal(1,"A not mounted");
        make_copy(1,32'd3,2);
        run_mount();
        if(!mounted || generation!=3 || entry_count!=2) $fatal(1,"newer B not selected");
        card_mem[4096+100]=8'hff;
        run_mount();
        if(!mounted || generation!=2) $fatal(1,"corrupt B not rejected");
        inject_io=1;
        make_copy(1,32'd4,3);
        run_mount();
        if(!mounted || !io_error || generation!=4) $fatal(1,"I/O A and valid B failed");
        inject_io=0;
        card_mem[4096+3592]=card_mem[4096+3592]^8'h01;
        run_mount();
        if(!mounted || generation!=2) $fatal(1,"bad commit CRC not rejected");
        $display("PASS sd_directory_mount blank/A/B/corrupt/fallback/IO/commit");
        $finish;
    end
endmodule
