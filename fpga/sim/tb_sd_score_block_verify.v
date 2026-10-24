`timescale 1ns/1ps
module tb_sd_score_block_verify;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    wire block_start,block_write,guard,done,valid,io_failed;
    wire [31:0] lba;
    wire [8:0] buffer_addr;
    reg [7:0] data_sector[0:511],log_sector[0:511];
    reg [31:0] active_lba=0;
    wire [7:0] buffer_rdata=(active_lba==32'd32768+2*8192+4096+7)
        ? log_sector[buffer_addr] : data_sector[buffer_addr];
    reg block_done=0;
    reg [7:0] block_error=0;
    reg [1:0] pending=0;
    integer requests=0,fail_at=0,i,timeout;
    reg [31:0] c;
    localparam [127:0] UUID=128'h00112233445566778899aabbccddeeff;
    localparam [63:0] EPOCH=64'h0102030405060708;
    sd_score_block_verify dut (
        .clk(clk),.rst_n(rst_n),.start(start),
        .slot(3'd2),.block_index(12'd7),.expected_bytes(10'd257),
        .uuid(UUID),.slot_epoch(EPOCH),.sector_count(32'd100000),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.block_start(block_start),
        .block_write(block_write),.block_lba(lba),
        .block_guard_valid(guard),.buffer_addr(buffer_addr),
        .buffer_rdata(buffer_rdata),.done(done),.valid(valid),
        .io_failed(io_failed)
    );
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] x;
        integer n;
        begin
            x=previous^{24'd0,octet};
            for(n=0;n<8;n=n+1)
                x=x[0] ? ((x>>1)^32'hedb88320) : (x>>1);
            crc_byte=x;
        end
    endfunction
    always @(posedge clk) begin
        block_done<=0;
        if(block_start) begin
            if(!guard || block_write) $fatal(1,"unsafe read request");
            if(requests==0 && lba!=32'd32768+2*8192+4096+7)
                $fatal(1,"expected log before data");
            if(requests==1 && lba!=32'd32768+2*8192+7)
                $fatal(1,"expected data after log");
            active_lba<=lba;
            requests=requests+1;
            pending<=2;
        end else if(pending!=0) begin
            pending<=pending-1'b1;
            if(pending==1) begin
                block_error<=requests==fail_at ? 8'h61 : 0;
                block_done<=1;
            end
        end
    end
    task run_once;
        begin
            requests=0;
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            timeout=0;
            while(!done && timeout<3000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(!done) $fatal(1,"verification timeout state=%0d",dut.state);
            @(negedge clk);
        end
    endtask
    initial begin
        for(i=0;i<512;i=i+1) begin
            data_sector[i]=i<257 ? (i[7:0]^8'h5a) : 0;
            log_sector[i]=0;
        end
        log_sector[0]="P"; log_sector[1]="S";
        log_sector[2]="L"; log_sector[3]="G";
        log_sector[4]=1; log_sector[6]=1; log_sector[7]=1;
        for(i=0;i<16;i=i+1) log_sector[8+i]=UUID[127-8*i -: 8];
        for(i=0;i<8;i=i+1) log_sector[24+i]=EPOCH[8*i +: 8];
        log_sector[32]=7;
        c=32'hffffffff;
        for(i=0;i<257;i=i+1) c=crc_byte(c,data_sector[i]);
        c=~c;
        for(i=0;i<4;i=i+1) log_sector[36+i]=c[8*i +: 8];
        c=32'hffffffff;
        for(i=0;i<40;i=i+1) c=crc_byte(c,log_sector[i]);
        c=~c;
        for(i=0;i<4;i=i+1) begin
            log_sector[40+i]=c[8*i +: 8];
            log_sector[44+i]=~c[8*i +: 8];
        end
        repeat(3) @(negedge clk); rst_n=1;
        run_once();
        if(!valid || io_failed || requests!=2)
            $fatal(1,"valid block not recovered");
        log_sector[25]=log_sector[25]^8'h01;
        run_once();
        if(valid || io_failed || requests!=1)
            $fatal(1,"corrupt log accepted");
        log_sector[25]=log_sector[25]^8'h01;
        data_sector[20]=data_sector[20]^8'h01;
        run_once();
        if(valid || io_failed || requests!=2)
            $fatal(1,"corrupt data accepted");
        data_sector[20]=data_sector[20]^8'h01;
        fail_at=1;
        run_once();
        if(valid || !io_failed || requests!=1)
            $fatal(1,"log I/O failure misclassified");
        fail_at=2;
        run_once();
        if(valid || !io_failed || requests!=2)
            $fatal(1,"data I/O failure misclassified");
        $display("PASS sd_score_block_verify");
        $finish;
    end
endmodule
