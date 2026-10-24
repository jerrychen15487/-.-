`timescale 1ns/1ps
module tb_sd_directory_entry_read;
    reg clk=0,rst_n=0,start=0,directory_b=0;
    always #10 clk=~clk;
    reg [2:0] entry_index=0,entry_count=2;
    reg [8:0] title_addr=0;
    wire [7:0] title_byte;
    wire block_start,guard,done,valid,io_failed;
    wire [31:0] lba,total_bytes,file_crc,capabilities,total_blocks;
    wire [8:0] addr;
    wire [127:0] uuid;
    wire [7:0] entry_state;
    wire [15:0] title_len;
    wire [63:0] epoch;
    reg block_done=0;
    reg [7:0] block_error=0;
    reg [7:0] directory_mem[0:3583],scratch[0:511];
    integer i,b,timeout,reads=0;
    sd_directory_entry_read dut (
        .clk(clk),.rst_n(rst_n),.start(start),
        .directory_b(directory_b),.entry_index(entry_index),
        .entry_count(entry_count),.sector_count(32'd100000),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.block_start(block_start),
        .block_lba(lba),.block_guard_valid(guard),
        .buffer_addr(addr),.buffer_rdata(scratch[addr]),
        .title_addr(title_addr),.title_byte(title_byte),
        .done(done),.valid(valid),.io_failed(io_failed),
        .uuid(uuid),.entry_state(entry_state),.title_len(title_len),
        .total_bytes(total_bytes),.file_crc(file_crc),
        .capabilities(capabilities),.total_blocks(total_blocks),
        .slot_epoch(epoch)
    );
    task make_entry;
        input integer index;
        input [7:0] letter;
        begin
            b=16+448*index;
            for(i=0;i<16;i=i+1) directory_mem[b+i]=i+1+index;
            directory_mem[b+16]=1;
            directory_mem[b+18]=1;
            directory_mem[b+21]=2; // 512 bytes
            directory_mem[b+24]=8'h1f;
            directory_mem[b+25]=8'h93;
            directory_mem[b+26]=8'hcd;
            directory_mem[b+27]=8'h67;
            directory_mem[b+32]=1; // one block
            directory_mem[b+37]=2; // 512-byte blocks
            directory_mem[b+38]=2; // PSC2
            directory_mem[b+40]=3+index;
            directory_mem[b+48]=letter;
        end
    endtask
    task run_read;
        input [2:0] index;
        begin
            @(negedge clk); entry_index=index; start=1;
            @(negedge clk); start=0;
            timeout=0;
            while(!done && timeout<10000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(!done) $fatal(1,"reader timeout index %0d",index);
        end
    endtask
    always @(posedge clk) begin
        block_done<=0;
        if(block_start) begin
            if(!guard || lba<16384 || lba>16390)
                $fatal(1,"unsafe read lba=%0d",lba);
            for(integer k=0;k<512;k=k+1)
                scratch[k]=directory_mem[(lba-16384)*512+k];
            reads=reads+1;
            block_done<=1;
        end
    end
    initial begin
        for(i=0;i<3584;i=i+1) directory_mem[i]=0;
        make_entry(0,"D"); make_entry(1,"X");
        repeat(4) @(negedge clk); rst_n=1;
        run_read(0);
        if(!valid || io_failed || total_bytes!=512 || title_len!=1 ||
           epoch!=3 || reads!=1) $fatal(1,"entry0 decode failed");
        title_addr=0; #1;
        if(title_byte!="D") $fatal(1,"entry0 title failed");
        run_read(1);
        if(!valid || io_failed || epoch!=4 || reads!=3)
            $fatal(1,"cross-sector entry1 failed");
        title_addr=0; #1;
        if(title_byte!="X") $fatal(1,"entry1 title failed");
        run_read(2);
        if(valid || io_failed || reads!=3)
            $fatal(1,"out-of-range entry read card");
        directory_mem[16+17]=1; // reserved field
        run_read(0);
        if(valid || io_failed) $fatal(1,"reserved corruption accepted");
        directory_mem[16+17]=0;
        directory_mem[16+48]=0; // NUL title
        run_read(0);
        if(valid || io_failed) $fatal(1,"invalid title accepted");
        $display("PASS sd_directory_entry_read normal/cross-sector/bounds/reserved/title");
        $finish;
    end
endmodule
