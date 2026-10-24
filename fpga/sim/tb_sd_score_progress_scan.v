`timescale 1ns/1ps
module tb_sd_score_progress_scan;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    reg [31:0] total_bytes=768;
    reg [7:0] data_mem[0:1][0:511],log_mem[0:1][0:511];
    reg [31:0] active_lba=0;
    wire [8:0] buffer_addr;
    wire active_log=active_lba>=32'd32768+4096;
    wire active_index=active_lba[0];
    wire [7:0] buffer_rdata=active_log ?
        log_mem[active_index][buffer_addr] :
        data_mem[active_index][buffer_addr];
    reg block_done=0;
    reg [7:0] block_error=0;
    reg [1:0] pending=0;
    integer requests=0,fail_at=0,i,j,timeout;
    reg [31:0] c;
    wire block_start,block_write,guard,done,io_failed,invalid_spec;
    wire [31:0] lba;
    wire [12:0] next_block;
    localparam [127:0] UUID=128'h00112233445566778899aabbccddeeff;
    localparam [63:0] EPOCH=64'h0102030405060708;
    sd_score_progress_scan dut (
        .clk(clk),.rst_n(rst_n),.start(start),
        .slot(3'd0),.total_bytes(total_bytes),
        .uuid(UUID),.slot_epoch(EPOCH),.sector_count(32'd100000),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.block_start(block_start),
        .block_write(block_write),.block_lba(lba),
        .block_guard_valid(guard),.buffer_addr(buffer_addr),
        .buffer_rdata(buffer_rdata),.done(done),
        .io_failed(io_failed),.invalid_spec(invalid_spec),
        .next_block(next_block)
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
    task make_block;
        input integer block_number;
        input integer length;
        integer k;
        reg [31:0] crc;
        begin
            for(k=0;k<512;k=k+1) begin
                data_mem[block_number][k]=k<length ?
                    (k[7:0]^block_number[7:0]^8'h5a) : 0;
                log_mem[block_number][k]=0;
            end
            log_mem[block_number][0]="P";
            log_mem[block_number][1]="S";
            log_mem[block_number][2]="L";
            log_mem[block_number][3]="G";
            log_mem[block_number][4]=1;
            log_mem[block_number][6]=length[7:0];
            log_mem[block_number][7]=length[9:8];
            for(k=0;k<16;k=k+1)
                log_mem[block_number][8+k]=UUID[127-8*k -: 8];
            for(k=0;k<8;k=k+1)
                log_mem[block_number][24+k]=EPOCH[8*k +: 8];
            log_mem[block_number][32]=block_number[7:0];
            crc=32'hffffffff;
            for(k=0;k<length;k=k+1)
                crc=crc_byte(crc,data_mem[block_number][k]);
            crc=~crc;
            for(k=0;k<4;k=k+1)
                log_mem[block_number][36+k]=crc[8*k +: 8];
            crc=32'hffffffff;
            for(k=0;k<40;k=k+1)
                crc=crc_byte(crc,log_mem[block_number][k]);
            crc=~crc;
            for(k=0;k<4;k=k+1) begin
                log_mem[block_number][40+k]=crc[8*k +: 8];
                log_mem[block_number][44+k]=~crc[8*k +: 8];
            end
        end
    endtask
    always @(posedge clk) begin
        block_done<=0;
        if(block_start) begin
            if(!guard || block_write ||
               !((lba>=32'd32768 && lba<=32'd32769) ||
                 (lba>=32'd36864 && lba<=32'd36865)))
                $fatal(1,"unsafe scan LBA %0d",lba);
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
            while(!done && timeout<6000) begin
                @(negedge clk); timeout=timeout+1;
            end
            if(!done) $fatal(1,"scan timeout state=%0d",dut.state);
            @(negedge clk);
        end
    endtask
    initial begin
        make_block(0,512);
        make_block(1,256);
        repeat(3) @(negedge clk); rst_n=1;
        run_once();
        if(next_block!=2 || io_failed || invalid_spec || requests!=4)
            $fatal(1,"two-block recovery failed next=%0d",next_block);
        // Simulate power loss: RTL reset, card contents preserved.
        @(negedge clk); rst_n=0;
        repeat(3) @(negedge clk); rst_n=1;
        run_once();
        if(next_block!=2 || requests!=4)
            $fatal(1,"post-reset recovery failed");
        total_bytes=512;
        run_once();
        if(next_block!=1 || requests!=2 || io_failed)
            $fatal(1,"exact-sector length recovery failed");
        total_bytes=768;
        data_mem[1][20]=data_mem[1][20]^8'h01;
        run_once();
        if(next_block!=1 || io_failed || requests!=4)
            $fatal(1,"corrupt second block counted");
        data_mem[1][20]=data_mem[1][20]^8'h01;
        log_mem[0][0]=8'h00;
        run_once();
        if(next_block!=0 || io_failed || requests!=1)
            $fatal(1,"corrupt first log counted");
        log_mem[0][0]="P";
        fail_at=3;
        run_once();
        if(next_block!=1 || !io_failed || requests!=3)
            $fatal(1,"I/O error misreported as recovered prefix");
        fail_at=0; total_bytes=0;
        run_once();
        if(!invalid_spec || requests!=0)
            $fatal(1,"invalid metadata caused card reads");
        $display("PASS sd_score_progress_scan");
        $finish;
    end
endmodule
