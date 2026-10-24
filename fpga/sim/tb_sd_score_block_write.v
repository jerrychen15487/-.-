`timescale 1ns/1ps
module tb_sd_score_block_write;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    reg [2:0] slot=2;
    reg [11:0] block_index=7;
    reg [9:0] valid_bytes=257;
    reg [127:0] uuid=128'h00112233445566778899aabbccddeeff;
    reg [63:0] epoch=64'h0102030405060708;
    wire [8:0] stage_addr;
    reg [7:0] stage_mem[0:511];
    wire [7:0] stage_byte=stage_mem[stage_addr];
    reg block_done=0;
    reg [7:0] block_error=0;
    wire block_start,block_write,guard,buffer_we,done,failed;
    wire [31:0] lba;
    wire [8:0] buffer_addr;
    wire [7:0] buffer_wdata;
    reg [7:0] scratch[0:511],data_sector[0:511],log_sector[0:511];
    integer writes=0,fail_at=0,i,timeout;
    reg [1:0] pending=0;
    reg [31:0] expected_crc;
    sd_score_block_write dut (
        .clk(clk),.rst_n(rst_n),.start(start),.slot(slot),
        .block_index(block_index),.valid_bytes(valid_bytes),.uuid(uuid),
        .slot_epoch(epoch),.sector_count(32'd100000),
        .stage_addr(stage_addr),.stage_byte(stage_byte),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.block_start(block_start),
        .block_write(block_write),.block_lba(lba),
        .block_guard_valid(guard),.buffer_we(buffer_we),
        .buffer_addr(buffer_addr),.buffer_wdata(buffer_wdata),
        .done(done),.failed(failed)
    );
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer n;
        begin
            c=previous^{24'd0,octet};
            for(n=0;n<8;n=n+1)
                c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction
    always @(posedge clk) begin
        block_done<=0;
        if(buffer_we) scratch[buffer_addr]=buffer_wdata;
        if(block_start) begin
            if(!guard || !block_write) $fatal(1,"unguarded write");
            if(writes==0 && lba!=32'd32768+2*8192+7)
                $fatal(1,"wrong data lba=%0d",lba);
            if(writes==1 && lba!=32'd32768+2*8192+4096+7)
                $fatal(1,"wrong log lba=%0d",lba);
            if(writes==0) for(i=0;i<512;i=i+1) data_sector[i]=scratch[i];
            if(writes==1) for(i=0;i<512;i=i+1) log_sector[i]=scratch[i];
            writes=writes+1;
            pending<=2;
        end else if(pending!=0) begin
            pending<=pending-1'b1;
            if(pending==1) begin
                block_error<=writes==fail_at ? 8'h61 : 0;
                block_done<=1;
            end
        end
    end
    task run_once;
        begin
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            timeout=0;
            while(!done && timeout<3000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(!done) $fatal(1,"timeout state=%0d",dut.state);
            @(negedge clk);
        end
    endtask
    initial begin
        for(i=0;i<512;i=i+1) stage_mem[i]=i[7:0]^8'h5a;
        repeat(3) @(negedge clk); rst_n=1;
        run_once();
        if(failed || writes!=2) $fatal(1,"expected two verified writes");
        expected_crc=32'hffffffff;
        for(i=0;i<257;i=i+1) begin
            if(data_sector[i]!=stage_mem[i]) $fatal(1,"data byte %0d",i);
            expected_crc=crc_byte(expected_crc,stage_mem[i]);
        end
        for(i=257;i<512;i=i+1)
            if(data_sector[i]!=0) $fatal(1,"padding byte %0d",i);
        expected_crc=~expected_crc;
        if(log_sector[0]!="P" || log_sector[3]!="G" ||
           log_sector[6]!=1 || log_sector[7]!=1 ||
           log_sector[32]!=7 || log_sector[36]!=expected_crc[7:0] ||
           log_sector[39]!=expected_crc[31:24])
            $fatal(1,"log metadata incorrect");
        expected_crc=32'hffffffff;
        for(i=0;i<40;i=i+1)
            expected_crc=crc_byte(expected_crc,log_sector[i]);
        expected_crc=~expected_crc;
        if({log_sector[43],log_sector[42],log_sector[41],log_sector[40]}!=expected_crc ||
           {log_sector[47],log_sector[46],log_sector[45],log_sector[44]}!=~expected_crc)
            $fatal(1,"log CRC incorrect");
        for(i=48;i<512;i=i+1)
            if(log_sector[i]!=0) $fatal(1,"log padding byte %0d",i);

        // A failed log write must not produce an acknowledgeable completion.
        writes=0; fail_at=2;
        run_once();
        if(!failed || writes!=2) $fatal(1,"log failure was acknowledged");
        writes=0; fail_at=1;
        run_once();
        if(!failed || writes!=1) $fatal(1,"data failure wrote a log");
        $display("PASS sd_score_block_write");
        $finish;
    end
endmodule
