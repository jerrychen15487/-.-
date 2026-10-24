`timescale 1ns/1ps
module tb_psc2_page_index;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,clear=0,byte_valid=0;
    reg [1:0] notation=1;
    reg [5:0] target_index=0;
    reg scan_done=0;
    reg [31:0] byte_offset=0;
    reg [7:0] byte_data=0;
    wire page_found;
    wire [31:0] page_id,bitmap_offset,bitmap_length;
    wire diag_pub_valid;
    wire [31:0] diag_pub_length,diag_pub_byte_offset;
    wire [4:0] diag_pub_page_field;
    reg [7:0] fixture[0:231455];
    integer fd,n,i;
    reg [1023:0] file_path;
    reg previous_found=0;
    reg [31:0] previous_id=0,previous_offset=0;
    psc2_page_index dut(
        .clk(clk),.rst_n(rst_n),.clear(clear),.notation(notation),
        .target_index(target_index),.scan_done(scan_done),
        .byte_valid(byte_valid),.byte_offset(byte_offset),
        .byte_data(byte_data),.page_found(page_found),
        .page_id(page_id),.bitmap_offset(bitmap_offset),
        .bitmap_length(bitmap_length),
        .diag_pub_valid(diag_pub_valid),
        .diag_pub_length(diag_pub_length),
        .diag_pub_byte_offset(diag_pub_byte_offset),
        .diag_pub_page_field(diag_pub_page_field)
    );
    // Assert the public contract on every observable cycle, not only at the
    // end of a fixture. A published page must never carry a raw bad length.
    always @(negedge clk) begin
        if(rst_n && page_found && bitmap_length!==32'd57600)
            $fatal(1,"page_found with invalid bitmap_length=%0d",bitmap_length);
    end
    always @(posedge clk) begin
        #1;
        if(!rst_n || clear) previous_found=0;
        else begin
            if(previous_found &&
               (!page_found || page_id!==previous_id ||
                bitmap_offset!==previous_offset ||
                bitmap_length!==32'd57600))
                $fatal(1,"published page changed before clear");
            previous_found=page_found;
            previous_id=page_id;
            previous_offset=bitmap_offset;
        end
    end
    task scan_index;
        input [1:0] wanted_notation;
        begin
            @(negedge clk);
            byte_valid=0;clear=1;notation=wanted_notation;
            @(negedge clk);
            clear=0;
            for(i=0;i<880;i=i+1) begin
                byte_valid=1;byte_offset=i;byte_data=fixture[i];
                @(negedge clk);
            end
            byte_valid=0;
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
        repeat(3) @(negedge clk);
        rst_n=1;
        scan_index(1);
        if(!page_found || page_id!==0 || bitmap_offset!==880 ||
           bitmap_length!==57600)
            $fatal(1,"staff index wrong id=%0d offset=%0d length=%0d",
                page_id,bitmap_offset,bitmap_length);
        if(!diag_pub_valid || diag_pub_length!==57600 ||
           diag_pub_byte_offset!==807 || diag_pub_page_field!==23)
            $fatal(1,"first publication snapshot mismatch");
        scan_index(2);
        if(!page_found || page_id!==2 || bitmap_offset!==116080 ||
           bitmap_length!==57600)
            $fatal(1,"jianpu index wrong id=%0d offset=%0d length=%0d",
                page_id,bitmap_offset,bitmap_length);
        if(diag_pub_length!==57600 || diag_pub_byte_offset!==807 ||
           diag_pub_page_field!==23)
            $fatal(1,"first publication snapshot overwritten");
        scan_index(3);
        if(page_found) $fatal(1,"unsupported notation selected");
        // Corrupt the first staff page's bitmap length. A later valid staff
        // page must still be selected, and no invalid span may escape.
        fixture[784+21]=0;
        scan_index(1);
        if(!page_found || page_id!==1 || bitmap_offset!==58480 ||
           bitmap_length!==57600)
            $fatal(1,"invalid first page not skipped id=%0d offset=%0d",
                page_id,bitmap_offset);
        // Reposition PAGE so the first record's final length byte lands at
        // byte 511, exactly on a sector boundary. This tests publication
        // independently of the next sector's data and request timing.
        for(i=0;i<96;i=i+1) fixture[488+i]=fixture[784+i];
        fixture[488+21]=8'he1;
        fixture[200]=8'he8;fixture[201]=8'h01;
        fixture[202]=0;fixture[203]=0;
        fixture[784+21]=8'he1;
        @(negedge clk);rst_n=0;byte_valid=0;
        repeat(2) @(negedge clk);
        rst_n=1;
        scan_index(1);
        if(!page_found || bitmap_length!==57600 ||
           diag_pub_byte_offset!==511 || diag_pub_page_field!==23)
            $fatal(1,"sector-boundary publication wrong");
        repeat(3) @(negedge clk);
        if(!page_found || bitmap_length!==57600 ||
           diag_pub_length!==57600 || diag_pub_byte_offset!==511)
            $fatal(1,"published page changed without clear");
        $display("PASS psc2_page_index: staff/jianpu/unsupported/bad-first-page/boundary");
        $finish;
    end
endmodule
