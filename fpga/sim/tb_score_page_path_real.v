`timescale 1ns/1ps
module tb_score_page_path_real;
    reg clk=0, pixel_clk=0, rst_n=0, key_n=1;
    always #10 clk=~clk;
    always #7 pixel_clk=~pixel_clk;

    wire sheet_mode,page_request,preview_request;
    wire [1:0] page_notation;
    wire [5:0] page_index,page_selected_index;
    wire [15:0] page_request_token,page_completed_token;
    wire [8:0] dev_addr;
    wire [7:0] dev_wdata;
    wire dev_we,dev_start,dev_write,dev_guard,storage_ready;
    wire [31:0] dev_lba,catalog_generation;
    reg dev_ready=1,dev_done=0;
    reg [7:0] dev_error=0;
    reg [2:0] busy=0;
    reg fail_next_block=0,fail_current=0;
    reg [7:0] block_mem[0:511];
    reg [7:0] fixture[0:759411];
    wire [7:0] dev_rdata=block_mem[dev_addr];
    wire page_begin,page_done,page_available,page_byte_valid;
    wire [3:0] page_result;
    wire [15:0] page_byte_index;
    wire [7:0] page_byte;
    wire [15:0] page_addr;
    wire [7:0] pixel_byte;
    wire page_ready_video;
    wire [23:0] rgb;
    reg [9:0] pix_x=0,pix_y=0;
    integer fd,n,i,block_base,requests=0,begins=0,results=0;
    integer bytes=0,expected_offset=8648,cycles=0;
    integer wrap_requests_before=0;
    reg [3:0] expected_result=4'd7;

    view_key_control #(.DEBOUNCE_CYCLES(4),.LONG_PRESS_UNITS(5),
        .DOUBLE_CLICK_CYCLES(25)) key_ctl (
        .clk(clk),.rst_n(rst_n),.key_n(key_n),
        .piano_demo_mode(),.preview_paused(),
        .preview_request(preview_request),.sheet_mode(sheet_mode),
        .page_request(page_request),.page_notation(page_notation),
        .page_index(page_index),.page_done(page_done),
        .page_available(page_available),
        .page_selected_index(page_selected_index),
        .page_request_token(page_request_token),
        .page_completed_token(page_completed_token)
    );
    score_store_v2 #(.MAX_SLOTS(1)) store (
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),
        .dev_ready(dev_ready),.dev_init_done(1'b1),
        .dev_done(dev_done),.dev_error(dev_error),
        .dev_rdata(dev_rdata),.sector_count(32'd100000),
        .dev_addr(dev_addr),.dev_wdata(dev_wdata),.dev_we(dev_we),
        .dev_start(dev_start),.dev_write(dev_write),
        .dev_guard(dev_guard),.dev_lba(dev_lba),
        .storage_ready(storage_ready),
        .catalog_generation(catalog_generation),
        .preview_request(preview_request),.preview_done(),
        .preview_available(),.preview_note_valid(),
        .preview_note_index(),.preview_start_tick(),
        .preview_duration_tick(),.preview_pitch(),
        .preview_part_mask(),.preview_bpm(),
        .page_request(page_request),.page_notation(page_notation),
        .page_index(page_index),
        .page_request_token(page_request_token),
        .page_completed_token(page_completed_token),
        .page_selected_index(page_selected_index),
        .page_begin(page_begin),.page_done(page_done),
        .page_available(page_available),.page_result(page_result),
        .page_byte_valid(page_byte_valid),
        .page_byte_index(page_byte_index),.page_byte(page_byte)
    );
    score_page_cache cache (
        .sys_clk(clk),.sys_rst_n(rst_n),
        .begin_load(page_begin || page_request),
        .byte_valid(page_byte_valid),.read_done(page_done),
        .read_available(page_available),
        .byte_index(page_byte_index),.byte_value(page_byte),
        .pixel_clk(pixel_clk),.pixel_rst_n(rst_n),
        .pixel_byte_addr(page_addr),.pixel_byte(pixel_byte),
        .ready_video(page_ready_video)
    );
    score_page_video video (
        .pixel_clk(pixel_clk),.pixel_rst_n(rst_n),
        .de(1'b1),.pix_x(pix_x),.pix_y(pix_y),
        .page_ready(page_ready_video),.page_byte(pixel_byte),
        .page_addr(page_addr),.rgb(rgb)
    );

    // Model the block device's buffer and delayed ready/done transaction.
    always @(posedge clk) begin
        dev_done<=0;
        if(rst_n) begin
            if(dev_start) begin
                if(!dev_ready || dev_write || !dev_guard || dev_we ||
                   dev_lba<32'd32768 || dev_lba>32'd34251)
                    $fatal(1,"bad SD request lba=%0d ready=%b guard=%b",
                        dev_lba,dev_ready,dev_guard);
                block_base=(dev_lba-32'd32768)*512;
                for(i=0;i<512;i=i+1)
                    block_mem[i]=block_base+i<759412 ?
                        fixture[block_base+i] : 0;
                dev_ready<=0;
                busy<=3;
                fail_current<=fail_next_block;
                fail_next_block<=0;
                dev_error<=0;
                requests=requests+1;
            end else if(busy!=0) begin
                busy<=busy-1'b1;
                if(busy==1) begin
                    dev_ready<=1;
                    dev_done<=1;
                    dev_error<=fail_current ? 8'h42 : 0;
                end
            end
            if(page_begin) begin
                begins=begins+1;
                bytes=0;
                expected_offset=(page_notation==1 ? 8648 : 411848)
                    +57600*(page_notation==1 ? page_index%7 : page_index%6);
            end
            if(page_byte_valid) begin
                if(page_byte_index!==bytes ||
                   page_byte!==fixture[expected_offset+bytes])
                    $fatal(1,"page byte %0d mismatch notation=%0d key=%0d expected_offset=%0d",
                        bytes,page_notation,page_index,expected_offset);
                bytes=bytes+1;
            end
            if(page_done) begin
                results=results+1;
                if(page_result!==expected_result ||
                   page_available!==(expected_result==4'd7) ||
                   bytes!=(expected_result==4'd7 ? 57600 : 0))
                    $fatal(1,"page result=%0d available=%b bytes=%0d first=%b found=%b complete=%b state=%0d",
                        page_result,page_available,bytes,
                        store.page_reader.indexer.first_valid,
                        store.page_reader.page_found,
                        store.page_reader.page_scan_complete,
                        store.page_reader.state);
                $display("page %0d: notation=%0d blocks=%0d bytes=%0d result=%0d",
                    results,page_notation,requests,bytes,page_result);
            end
            cycles=cycles+1;
            if(cycles>4000000) $fatal(1,"page path timeout");
        end
    end

    task press_key;
        input integer hold_cycles;
        begin
            @(negedge clk);key_n=0;
            repeat(hold_cycles) @(negedge clk);
            key_n=1;
            repeat(7) @(negedge clk);
            repeat(30) @(negedge clk);
        end
    endtask
    task tap_key;
        begin
            @(negedge clk);key_n=0;
            repeat(12) @(negedge clk);
            key_n=1;
            repeat(7) @(negedge clk);
        end
    endtask
    task check_pixel;
        input [9:0] x,y;
        reg [15:0] address;
        reg [10:0] source_x;
        reg bit_value;
        begin
            @(negedge pixel_clk);pix_x=x;pix_y=y;
            source_x=(x*3)>>1;
            address=y*80+(x>>3);
            repeat(2) @(negedge pixel_clk);
            bit_value=fixture[expected_offset+y*120+(source_x>>3)][7-(source_x&7)];
            if(page_addr!==address ||
               rgb!==(bit_value ? 24'h101828 : 24'hF8FAFC))
                $fatal(1,"pixel mismatch (%0d,%0d) rgb=%h",x,y,rgb);
        end
    endtask
    initial begin
        fd=$fopen("sim/tianzhen-fixture.pseq","rb");
        if(fd==0) $fatal(1,"missing real PSC2 fixture");
        n=$fread(fixture,fd);
        $fclose(fd);
        if(n!=759412) $fatal(1,"fixture size %0d",n);
        repeat(3) @(negedge clk);
        rst_n=1;
        // The real catalog was verified on device; seed its committed slot
        // to isolate the page request, SD ownership and video boundaries.
        @(negedge clk);
        store.state=6'd9;
        store.entry_state[0]=2;
        store.entry_total[0]=759412;
        store.card_fault=0;
        @(negedge clk);
        if(!storage_ready) $fatal(1,"store not ready");
        press_key(32);
        if(!sheet_mode || page_notation!=1)
            $fatal(1,"key did not request staff page");
        wait(results==1);
        repeat(6) @(negedge pixel_clk);
        if(!page_ready_video || begins!=1)
            $fatal(1,"staff page not published");
        check_pixel(0,0);
        check_pixel(320,240);
        check_pixel(639,479);
        for(n=0;n<640;n=n+1)
            check_pixel(n,120);
        press_key(12);
        if(!sheet_mode || page_notation!=2)
            $fatal(1,"key did not request jianpu page");
        wait(results==2);
        repeat(6) @(negedge pixel_clk);
        if(!page_ready_video || begins!=2)
            $fatal(1,"jianpu page not published");
        check_pixel(0,0);
        check_pixel(320,240);
        check_pixel(639,479);
        for(n=0;n<640;n=n+1)
            check_pixel(n,360);
        expected_result=4'd4;
        fail_next_block=1;
        press_key(12);
        wait(results==3);
        repeat(6) @(negedge pixel_clk);
        if(page_ready_video) $fatal(1,"failed SD read exposed stale page");
        expected_result=4'd3;
        store.entry_state[0]=0;
        press_key(12);
        wait(results==4);
        repeat(6) @(negedge pixel_clk);
        if(page_ready_video) $fatal(1,"missing slot exposed stale page");
        store.entry_state[0]=2;
        store.entry_total[0]=80;
        expected_result=4'd8;
        press_key(12);
        wait(results==5);
        store.entry_total[0]=60000;
        expected_result=4'd9;
        press_key(12);
        wait(results==6);
        store.entry_total[0]=100;
        expected_result=4'd6;
        press_key(12);
        wait(results==7);
        // A committed catalog entry whose advertised length cannot contain
        // even one page must be rejected at the controller boundary.  The
        // 38,516-byte value is the low 16 bits of the real 759,412-byte song.
        store.entry_total[0]=38516;
        expected_result=4'd12;
        press_key(12);
        wait(results==8);
        repeat(6) @(negedge pixel_clk);
        if(page_ready_video) $fatal(1,"invalid or absent page exposed stale page");
        store.entry_total[0]=759412;
        expected_result=4'd7;
        tap_key;
        tap_key;
        wait(results==9);
        repeat(6) @(negedge pixel_clk);
        if(page_index!=1 || page_notation!=2 || !page_ready_video ||
           expected_offset!=469448)
            $fatal(1,"double-click did not load second jianpu page");
        check_pixel(320,240);
        // Walk the remaining jianpu pages, then wrap to page zero. The
        // real song has six jianpu pages and seven staff pages.
        for(n=2;n<=6;n=n+1) begin
            if(n==6) wrap_requests_before=requests;
            tap_key;
            tap_key;
            wait(results==n+8);
            repeat(6) @(negedge pixel_clk);
            if(page_index!==(n==6 ? 0:n) || page_notation!=2 ||
               !page_ready_video)
                $fatal(1,"jianpu navigation failed at step %0d",n);
            if(n==6 && requests-wrap_requests_before>150)
                $fatal(1,"jianpu wrap scanned bitmap: %0d blocks",
                    requests-wrap_requests_before);
            check_pixel(320,240);
        end
        press_key(12);
        wait(results==15);
        repeat(6) @(negedge pixel_clk);
        if(page_index!=0 || page_notation!=1 || !page_ready_video)
            $fatal(1,"staff switch failed after jianpu wrap");
        check_pixel(320,240);
        for(n=1;n<=7;n=n+1) begin
            if(n==7) wrap_requests_before=requests;
            tap_key;
            tap_key;
            wait(results==n+15);
            repeat(6) @(negedge pixel_clk);
            if(page_index!==(n==7 ? 0:n) || page_notation!=1 ||
               !page_ready_video)
                $fatal(1,"staff navigation failed at step %0d",n);
            if(n==7 && requests-wrap_requests_before>150)
                $fatal(1,"staff wrap scanned bitmap: %0d blocks",
                    requests-wrap_requests_before);
            check_pixel(320,240);
        end
        // Queue page 2 while page 1 is still reading. Once page 1
        // completes, a further double-click must target page 3, not repeat
        // page 2 because the older completion rewound the requested index.
        tap_key;tap_key;
        tap_key;tap_key;
        if(page_index!=2) $fatal(1,"rapid page requests not accumulated");
        wait(results==23);
        tap_key;tap_key;
        wait(results==25);
        repeat(6) @(negedge pixel_clk);
        if(page_index!=3 || page_notation!=1 || !page_ready_video)
            $fatal(1,"stale completion rewound rapid page navigation");
        check_pixel(320,240);
        if(requests<100 || cycles>4000000)
            $fatal(1,"missing SD traffic");
        $display("PASS real PSC2 key/store/SD/cache/video: %0d blocks, %0d cycles",
            requests,cycles);
        $finish;
    end
endmodule
