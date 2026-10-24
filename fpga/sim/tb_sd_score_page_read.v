`timescale 1ns/1ps
module tb_sd_score_page_read;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0,block_done=0;
    reg [1:0] notation=1;
    reg [7:0] block_error=0;
    wire block_start,block_write,block_guard_valid;
    wire [31:0] block_lba;
    wire [8:0] buffer_addr;
    wire bitmap_byte_valid,done,found,io_failed,invalid_spec;
    wire [2:0] invalid_reason;
    wire diag_err_valid,diag_err_page_found,diag_err_index_clear;
    wire [2:0] diag_err_state;
    wire [31:0] diag_err_length,diag_err_offset,diag_err_total;
    wire diag_pub_valid;
    wire [31:0] diag_pub_length,diag_pub_byte_offset;
    wire [4:0] diag_pub_page_field;
    wire [15:0] bitmap_byte_index;
    wire [7:0] bitmap_byte;
    wire [31:0] file_pos=((block_lba-32'd32768)<<9)+buffer_addr;
    reg [7:0] fixture[0:231551];
    reg [31:0] test_total=231456;
    wire [7:0] buffer_rdata=fixture[file_pos];
    reg [1023:0] file_path;
    integer fd,n,i,reads,bytes,cycles,expected_base;
    reg inject_fault=0;
    sd_score_page_read dut(
        .clk(clk),.rst_n(rst_n),.start(start),.slot(3'd0),
        .notation(notation),.page_index(6'd0),
        .total_bytes(test_total),
        .sector_count(32'd100000),.block_ready(1'b1),
        .block_done(block_done),.block_error(block_error),
        .buffer_rdata(buffer_rdata),.block_start(block_start),
        .block_write(block_write),.block_lba(block_lba),
        .block_guard_valid(block_guard_valid),.buffer_addr(buffer_addr),
        .bitmap_byte_valid(bitmap_byte_valid),
        .bitmap_byte_index(bitmap_byte_index),.bitmap_byte(bitmap_byte),
        .done(done),.found(found),.io_failed(io_failed),
        .invalid_spec(invalid_spec),.invalid_reason(invalid_reason),
        .diag_err_valid(diag_err_valid),
        .diag_err_page_found(diag_err_page_found),
        .diag_err_index_clear(diag_err_index_clear),
        .diag_err_state(diag_err_state),
        .diag_err_length(diag_err_length),
        .diag_err_offset(diag_err_offset),.diag_err_total(diag_err_total),
        .diag_pub_valid(diag_pub_valid),
        .diag_pub_length(diag_pub_length),
        .diag_pub_byte_offset(diag_pub_byte_offset),
        .diag_pub_page_field(diag_pub_page_field)
    );
    always @(negedge clk) begin
        if(rst_n && !inject_fault && dut.page_found &&
           dut.bitmap_length!==32'd57600)
            $fatal(1,"reader saw impossible page publication");
    end
    always @(posedge clk) begin
        if(!rst_n) block_done<=0;
        else begin
            block_done<=block_start;
            if(block_start) begin
                if(block_write || !block_guard_valid ||
                   block_lba<32'd32768 || block_lba>=32'd32768+4096)
                    $fatal(1,"invalid SD request lba=%0d",block_lba);
                reads=reads+1;
            end
            if(bitmap_byte_valid) begin
                if(bitmap_byte_index!==bytes ||
                   bitmap_byte!==fixture[expected_base+bytes])
                    $fatal(1,"bitmap mismatch byte %0d got=%02x expected=%02x",
                        bytes,bitmap_byte,fixture[expected_base+bytes]);
                bytes=bytes+1;
            end
            cycles=cycles+1;
            if(cycles>310000) $fatal(1,"page read timeout");
        end
    end
    task run_page;
        input [1:0] wanted;
        input integer base;
        begin
            @(negedge clk);
            notation=wanted;expected_base=base;
            reads=0;bytes=0;cycles=0;start=1;
            @(negedge clk);
            start=0;
            wait(done);
            @(negedge clk);
            if(!found || io_failed || invalid_spec || bytes!=57600)
                $fatal(1,"page read failed notation=%0d bytes=%0d reads=%0d",
                    wanted,bytes,reads);
            if(reads<113) $fatal(1,"too few sector requests: %0d",reads);
        end
    endtask
    task run_reject;
        input [1:0] wanted;
        input [7:0] error_value;
        input expected_io_failure;
        input expected_invalid;
        input [2:0] expected_reason;
        begin
            @(negedge clk);
            notation=wanted;block_error=error_value;
            reads=0;bytes=0;cycles=0;start=1;
            @(negedge clk);
            start=0;
            wait(done);
            @(negedge clk);
            if(found || bytes!=0 || io_failed!==expected_io_failure ||
               invalid_spec!==expected_invalid ||
               invalid_reason!==expected_reason)
                $fatal(1,"reject status wrong notation=%0d io=%0d spec=%0d reason=%0d bytes=%0d",
                    wanted,io_failed,invalid_spec,invalid_reason,bytes);
            block_error=0;
        end
    endtask
    initial begin
        if(!$value$plusargs("FILE=%s",file_path))
            $fatal(1,"pass +FILE=sim/engineering_test.pseq");
        fd=$fopen(file_path,"rb");
        if(fd==0) $fatal(1,"cannot open %s",file_path);
        n=$fread(fixture,fd);
        $fclose(fd);
        if(n!=231456) $fatal(1,"wrong fixture size %0d",n);
        reads=0;bytes=0;cycles=0;expected_base=0;
        repeat(3) @(negedge clk);
        rst_n=1;
        run_page(1,880);
        run_page(2,116080);
        // Even an injected downstream mismatch cannot invalidate a PAGE
        // already checked by the indexer; the reader uses the fixed span.
        @(negedge clk);
        notation=1;expected_base=880;reads=0;bytes=0;cycles=0;start=1;
        @(negedge clk);
        start=0;
        wait(!dut.page_found);
        wait(dut.page_found);
        @(negedge clk);
        inject_fault=1;
        force dut.bitmap_length=32'd57599;
        wait(done);
        @(negedge clk);
        release dut.bitmap_length;
        inject_fault=0;
        if(invalid_spec || !found || bytes!=57600 || diag_err_valid ||
           !diag_pub_valid ||
           diag_pub_length!==57600 || diag_pub_byte_offset!==807 ||
           diag_pub_page_field!==23)
            $fatal(1,"redundant reader length check still active");
        run_page(1,880);
        // A malformed PSC2 PAGE is rejected by the indexer itself, before
        // any bitmap byte can be streamed or cached.
        fixture[784+21]=0;fixture[808+21]=0;
        run_reject(1,0,0,0,0);
        fixture[784+21]=8'he1;fixture[808+21]=8'he1;
        fixture[790]=8'd3;fixture[814]=8'd3;
        run_reject(1,0,0,0,0); // valid file with no requested notation page
        fixture[790]=8'd1;fixture[814]=8'd1;
        run_reject(3,0,0,1,0);
        run_reject(1,8'h31,1,0,0);
        test_total=1000;
        run_reject(1,0,0,1,1);
        test_total=100000;
        run_reject(2,0,0,1,2);
        test_total=130000;
        run_reject(2,0,0,1,4);
        test_total=231456;
        // A valid PAGE descriptor can point after BITMAP. Put its 4 records
        // at EOF, so the matching record's last byte is the final file byte.
        for(i=0;i<96;i=i+1) fixture[231456+i]=fixture[784+i];
        fixture[231456+54]=8'd1;
        fixture[200]=8'h20;fixture[201]=8'h88;
        fixture[202]=8'h03;fixture[203]=8'h00;
        test_total=231552;
        run_page(2,173680);
        $display("PASS sd_score_page_read: staff/jianpu/EOF, unavailable/error, no writes");
        $finish;
    end
endmodule
