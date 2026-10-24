`timescale 1ns/1ps
module tb_sd_directory_init;
    reg clk=0,rst_n=0,init_start=0,mount_start=0,read_mode=0;
    always #10 clk=~clk;
    wire init_req,init_guard,init_done,init_failed,init_we;
    wire [31:0] init_lba;
    wire [8:0] init_addr;
    wire [7:0] init_data;
    wire mount_req,mount_guard,mount_done,mounted,io_error,blank_media;
    wire [31:0] mount_lba,generation;
    wire [8:0] mount_addr;
    wire [2:0] entry_count;
    wire a_valid,b_valid;
    wire [31:0] a_generation,b_generation;
    wire [2:0] a_entry_count,b_entry_count;
    reg block_done=0;
    reg [7:0] block_error=0;
    wire req=read_mode ? mount_req : init_req;
    wire guard=read_mode ? mount_guard : init_guard;
    wire [31:0] lba=read_mode ? mount_lba : init_lba;
    reg [7:0] card_mem[0:8191],scratch[0:511];
    reg [31:0] active_lba=16384;
    reg [2:0] pending=0;
    integer writes=0,reads=0,fail_write=-1,i;
    wire [7:0] read_data=card_mem[(active_lba-32'd16384)*512+mount_addr];
    sd_directory_init initializer(clk,rst_n,init_start,1'b1,block_done,
        block_error,32'd32768,init_req,init_lba,init_guard,
        init_we,init_addr,init_data,init_done,init_failed);
    sd_directory_mount mounter(clk,rst_n,mount_start,1'b1,block_done,
        block_error,32'd32768,mount_req,mount_lba,mount_guard,
        mount_addr,read_data,mount_done,mounted,io_error,blank_media,generation,entry_count,
        a_valid,b_valid,a_generation,b_generation,a_entry_count,b_entry_count);
    always @(posedge clk) begin
        block_done<=0;
        if(!rst_n) pending<=0;
        else begin
            if(!read_mode && init_we) scratch[init_addr]<=init_data;
            if(req) begin
                if(!guard || lba<16384 || lba>16399)
                    $fatal(1,"invalid directory LBA %0d",lba);
                active_lba<=lba;
                if(!read_mode) begin
                    if(lba!=32'd16384+writes)
                        $fatal(1,"write order wrong lba=%0d writes=%0d",lba,writes);
                    if(writes!=fail_write)
                        for(i=0;i<512;i=i+1)
                            card_mem[(lba-16384)*512+i]=scratch[i];
                    writes=writes+1;
                end else reads=reads+1;
                pending<=3;
            end else if(pending!=0) begin
                pending<=pending-1'b1;
                if(pending==1) begin
                    block_error<=!read_mode && (writes-1)==fail_write ? 8'h61 : 0;
                    block_done<=1;
                end
            end
        end
    end
    task blank;
        begin for(i=0;i<8192;i=i+1) card_mem[i]=0; end
    endtask
    task start_init;
        integer timeout;
        begin
            read_mode=0;
            @(negedge clk); init_start=1;
            @(negedge clk); init_start=0;
            timeout=0;
            while(!init_done && timeout<25000) begin @(negedge clk); timeout=timeout+1; end
            if(!init_done) $fatal(1,"init timeout state=%0d",initializer.state);
            @(negedge clk);
        end
    endtask
    task start_mount;
        integer timeout;
        begin
            read_mode=1;
            @(negedge clk); mount_start=1;
            @(negedge clk); mount_start=0;
            timeout=0;
            while(!mount_done && timeout<25000) begin @(negedge clk); timeout=timeout+1; end
            if(!mount_done) $fatal(1,"mount timeout state=%0d",mounter.state);
            @(negedge clk);
        end
    endtask
    initial begin
        blank(); repeat(3) @(negedge clk); rst_n=1;
        repeat(100) @(negedge clk);
        if(writes!=0) $fatal(1,"initializer auto-wrote");
        start_init();
        if(init_failed || writes!=16) $fatal(1,"full init failed writes=%0d",writes);
        start_mount();
        if(!mounted || generation!=2 || entry_count!=0)
            $fatal(1,"initialized directory not mounted gen=%0d",generation);
        blank(); writes=0; fail_write=10; block_error=0;
        start_init();
        if(!init_failed || writes!=11) $fatal(1,"injected write failure missed");
        block_error=0; fail_write=-1;
        start_mount();
        if(!mounted || generation!=1 || entry_count!=0)
            $fatal(1,"A fallback after B failure failed gen=%0d",generation);
        $display("PASS sd_directory_init explicit/16 ordered writes/mount/failure fallback");
        $finish;
    end
endmodule
