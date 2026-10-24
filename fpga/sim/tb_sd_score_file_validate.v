`timescale 1ns/1ps
module tb_sd_score_file_validate;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,start=0,block_done=0;
    reg [7:0] block_error=0;
    wire block_start,block_guard_valid,done,io_failed,bad_crc,bad_package;
    wire [31:0] block_lba;
    wire [8:0] buffer_addr;
    reg [7:0] file_bytes[0:231455];
    reg [31:0] active_sector=0;
    wire [31:0] file_addr=active_sector*512+buffer_addr;
    wire [7:0] buffer_rdata=(file_addr<231456) ? file_bytes[file_addr] : 0;
    integer fd,n,failures=0;
    reg [1023:0] file_path;
    sd_score_file_validate dut (
        .clk(clk),.rst_n(rst_n),.start(start),.slot(3'd0),
        .total_bytes(32'd231456),.file_crc(32'ha3653545),
        .capabilities(32'd7),.sector_count(32'd67108864),
        .uuid(128'h12345678123456789abcdef012345678),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(block_error),.block_start(block_start),
        .block_lba(block_lba),.block_guard_valid(block_guard_valid),
        .buffer_addr(buffer_addr),.buffer_rdata(buffer_rdata),
        .done(done),.io_failed(io_failed),.bad_crc(bad_crc),
        .bad_package(bad_package)
    );
    always @(posedge clk) begin
        block_done<=block_start;
        if(block_start) begin
            if(!block_guard_valid || block_lba<32768) begin
                $display("FAIL invalid LBA %d",block_lba);
                $fatal(1);
            end
            active_sector<=block_lba-32768;
        end
    end
    task run_check;
        input expected_bad_crc,expected_bad_package;
        begin
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            wait(done);
            if(io_failed || bad_crc!==expected_bad_crc ||
               bad_package!==expected_bad_package) begin
                $display("FAIL crc=%b package=%b io=%b expected=%b/%b pos=%d section=%d/%d",
                    bad_crc,bad_package,io_failed,expected_bad_crc,
                    expected_bad_package,dut.absolute_pos,
                    dut.section_index,dut.section_count);
                failures=failures+1;
            end
            @(negedge clk);
        end
    endtask
    initial begin
        if(!$value$plusargs("FILE=%s",file_path))
            $fatal(1,"pass +FILE=engineering.pseq");
        fd=$fopen(file_path,"rb");
        if(fd==0) $fatal(1,"cannot open %s",file_path);
        n=$fread(file_bytes,fd);
        $fclose(fd);
        if(n!=231456) $fatal(1,"wrong fixture size %d",n);
        repeat(5) @(negedge clk); rst_n=1;
        run_check(0,0);
        file_bytes[1000]=file_bytes[1000]^8'h01;
        run_check(1,0);
        file_bytes[1000]=file_bytes[1000]^8'h01;
        file_bytes[0]=0;
        run_check(1,1);
        file_bytes[0]="P";
        // First descriptor's required section flag must remain set.
        file_bytes[64+6]=file_bytes[64+6]^8'h01;
        run_check(1,1);
        if(failures!=0) $fatal(1,"%d cases failed",failures);
        $display("PASS PSC2 valid/corrupt-payload/corrupt-header/corrupt-descriptor");
        $finish;
    end
    initial begin
        #500000000;
        $fatal(1,"validator timeout state=%d pos=%d",dut.state,
            dut.absolute_pos);
    end
endmodule
