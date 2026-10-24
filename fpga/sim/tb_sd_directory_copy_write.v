`timescale 1ns/1ps
module tb_sd_directory_copy_write;
    reg clk=0,rst_n=0,write_start=0,mount_start=0,read_mode=0;
    always #10 clk=~clk;
    reg target_b=1;
    reg [31:0] new_generation=4;
    reg [2:0] new_count=0;
    wire write_req,write_guard,write_done,write_failed,write_we;
    wire [31:0] write_lba;
    wire [11:0] source_addr;
    wire [8:0] write_addr;
    wire [7:0] write_data;
    wire mount_req,mount_guard,mount_done,mounted,mount_error,blank;
    wire [31:0] mount_lba,generation;
    wire [2:0] count;
    wire [8:0] mount_addr;
    wire a_valid,b_valid;
    wire [31:0] a_gen,b_gen;
    wire [2:0] a_count,b_count;
    reg block_done=0;
    reg [7:0] block_error=0;
    reg [7:0] card_mem[0:8191],scratch[0:511],source_mem[0:3583];
    reg [31:0] active_lba=16384;
    reg [2:0] pending=0;
    integer writes=0,fail_write=-1,i,timeout;
    wire req=read_mode ? mount_req : write_req;
    wire guard=read_mode ? mount_guard : write_guard;
    wire [31:0] lba=read_mode ? mount_lba : write_lba;
    sd_directory_copy_write writer (
        .clk(clk),.rst_n(rst_n),.start(write_start),
        .target_b(target_b),.new_generation(new_generation),
        .new_entry_count(new_count),.sector_count(32'd100000),
        .source_addr(source_addr),.source_byte(source_mem[source_addr]),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.block_start(write_req),
        .block_lba(write_lba),.block_guard_valid(write_guard),
        .buffer_we(write_we),.buffer_addr(write_addr),
        .buffer_wdata(write_data),.done(write_done),.failed(write_failed)
    );
    sd_directory_mount mounter (
        .clk(clk),.rst_n(rst_n),.start(mount_start),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.sector_count(32'd100000),
        .block_start(mount_req),.block_lba(mount_lba),
        .block_guard_valid(mount_guard),.buffer_addr(mount_addr),
        .buffer_rdata(card_mem[(active_lba-16384)*512+mount_addr]),
        .done(mount_done),.mounted(mounted),.io_error(mount_error),
        .blank_media(blank),.generation(generation),.entry_count(count),
        .a_valid(a_valid),.b_valid(b_valid),
        .a_generation(a_gen),.b_generation(b_gen),
        .a_entry_count(a_count),.b_entry_count(b_count)
    );
    always @(posedge clk) begin
        block_done<=0;
        if(!rst_n) pending<=0;
        else begin
            if(!read_mode && write_we) scratch[write_addr]<=write_data;
            if(req) begin
                if(!guard || lba<16384 || lba>16399)
                    $fatal(1,"unsafe directory LBA %0d",lba);
                active_lba<=lba;
                if(!read_mode) begin
                    if(lba!=(target_b ? 16392 : 16384)+(writes%8))
                        $fatal(1,"write order lba=%0d writes=%0d",lba,writes);
                    if(writes!=fail_write)
                        for(i=0;i<512;i=i+1)
                            card_mem[(lba-16384)*512+i]=scratch[i];
                    writes=writes+1;
                end
                pending<=3;
            end else if(pending!=0) begin
                pending<=pending-1'b1;
                if(pending==1) begin
                    block_error<=!read_mode && writes-1==fail_write ? 8'h61 : 0;
                    block_done<=1;
                end
            end
        end
    end
    task publish;
        begin
            read_mode=0;
            @(negedge clk); write_start=1;
            @(negedge clk); write_start=0;
            timeout=0;
            while(!write_done && timeout<20000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(!write_done) $fatal(1,"writer timeout");
            @(negedge clk);
        end
    endtask
    task mount;
        begin
            read_mode=1; block_error=0;
            @(negedge clk); mount_start=1;
            @(negedge clk); mount_start=0;
            timeout=0;
            while(!mount_done && timeout<20000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(!mount_done) $fatal(1,"mount timeout");
            @(negedge clk);
        end
    endtask
    initial begin
        for(i=0;i<8192;i=i+1) card_mem[i]=0;
        for(i=0;i<3584;i=i+1) source_mem[i]=0;
        repeat(4) @(negedge clk); rst_n=1;
        repeat(10) @(negedge clk);
        if(writes!=0) $fatal(1,"writer auto-wrote");
        publish();
        if(write_failed || writes!=8) $fatal(1,"empty B4 publish failed");
        mount();
        if(!mounted || generation!=4 || count!=0 || !b_valid)
            $fatal(1,"B4 did not mount");
        // Publish one synthetic entry into A5 and verify body is preserved.
        source_mem[16]=8'h55; source_mem[32]=1;
        source_mem[34]=1; source_mem[37]=2;
        source_mem[48]=1; source_mem[53]=2;
        source_mem[54]=2; source_mem[56]=5;
        source_mem[64]="T";
        target_b=0; new_generation=5; new_count=1;
        publish(); mount();
        if(write_failed || writes!=16 || !a_valid || generation!=5 ||
           count!=1 || card_mem[16]!=8'h55 || card_mem[64]!="T")
            $fatal(1,"A5 body/commit failed");
        // Interrupted next B6: old A5 remains the selected valid copy.
        target_b=1; new_generation=6; new_count=0;
        fail_write=23; publish();
        if(!write_failed || writes!=24) $fatal(1,"injected commit failure missed");
        fail_write=-1; mount();
        if(!mounted || generation!=5 || count!=1 || !a_valid)
            $fatal(1,"rollback after failed B6 commit failed");
        $display("PASS sd_directory_copy_write empty/body/CRC/commit-last/rollback");
        $finish;
    end
endmodule
