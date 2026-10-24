`timescale 1ns/1ps
module tb_score_store_v2;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,uart_rx=1;
    wire uart_tx;
    wire [8:0] dev_addr;
    wire [7:0] dev_wdata;
    wire dev_we,dev_start,dev_write,dev_guard,storage_ready;
    wire [31:0] dev_lba,catalog_generation;
    reg dev_done=0;
    reg [7:0] dev_error=0;
    reg [7:0] buffer[0:511];
    reg [7:0] dir_a[0:4095],dir_b[0:4095];
    reg [7:0] data0[0:511],data1[0:511];
    reg [7:0] log0[0:511],log1[0:511];
    reg [7:0] payload[0:1023],song[0:231];
    reg [7:0] response[0:1023];
    reg [9:0] response_count=0;
    reg [10:0] response_total=0;
    reg response_ready=0;
    reg [31:0] crc;
    reg [31:0] expected_session,expected_seq;
    reg fail_once=0;
    reg page_request=0;
    wire page_done,page_available;
    wire [3:0] page_result;
    reg [31:0] fail_lba=0;
    integer i,n,case_count=0;
    wire [7:0] dev_rdata=buffer[dev_addr];
`ifdef SINGLE_SLOT
    score_store_v2 #(.MAX_SLOTS(1)) dut (
`else
    score_store_v2 dut (
`endif
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .dev_ready(1'b1),.dev_init_done(1'b1),
        .dev_done(dev_done),.dev_error(dev_error),
        .dev_rdata(dev_rdata),.sector_count(32'd67108864),
        .dev_addr(dev_addr),.dev_wdata(dev_wdata),
        .dev_we(dev_we),.dev_start(dev_start),
        .dev_write(dev_write),.dev_guard(dev_guard),
        .dev_lba(dev_lba),.storage_ready(storage_ready),
        .catalog_generation(catalog_generation),
        .page_request(page_request),.page_notation(2'd1),
        .page_request_token(16'd0),.page_completed_token(),
        .page_done(page_done),.page_available(page_available),
        .page_result(page_result)
    );
    function [31:0] crc_byte;
        input [31:0] prior;
        input [7:0] value;
        reg [31:0] c;
        integer k;
        begin
            c=prior^{24'd0,value};
            for(k=0;k<8;k=k+1)
                c=c[0] ? ((c>>1)^32'hedb88320):(c>>1);
            crc_byte=c;
        end
    endfunction
    task store_le32;
        input integer offset;
        input [31:0] value;
        begin
            payload[offset]=value[7:0];
            payload[offset+1]=value[15:8];
            payload[offset+2]=value[23:16];
            payload[offset+3]=value[31:24];
        end
    endtask
    task song_le32;
        input integer offset;
        input [31:0] value;
        begin
            song[offset]=value[7:0];
            song[offset+1]=value[15:8];
            song[offset+2]=value[23:16];
            song[offset+3]=value[31:24];
        end
    endtask
    task song_le16;
        input integer offset;
        input [15:0] value;
        begin
            song[offset]=value[7:0];
            song[offset+1]=value[15:8];
        end
    endtask
    task transmit_byte;
        input [7:0] value;
        integer bitno;
        begin
            uart_rx=0;repeat(50) @(negedge clk);
            for(bitno=0;bitno<8;bitno=bitno+1) begin
                uart_rx=value[bitno];repeat(50) @(negedge clk);
            end
            uart_rx=1;repeat(50) @(negedge clk);
        end
    endtask
    task send_request;
        input [7:0] kind;
        input [31:0] session,seq;
        input integer length;
        reg [31:0] c;
        integer k;
        reg [7:0] value;
        begin
            response_count=0;response_total=0;response_ready=0;
            expected_session=session;expected_seq=seq;
            c=32'hffffffff;
            transmit_byte(8'ha5);transmit_byte(8'h5a);
            for(k=2;k<16+length;k=k+1) begin
                case(k)
                    2:value=2;3:value=kind;
                    4,5,6,7:value=session[8*(k-4) +: 8];
                    8,9,10,11:value=seq[8*(k-8) +: 8];
                    12:value=length[7:0];
                    13:value=(length>>8)&8'hff;
                    14,15:value=0;
                    default:value=payload[k-16];
                endcase
                c=crc_byte(c,value);
                transmit_byte(value);
            end
            c=~c;
            for(k=0;k<4;k=k+1)
                transmit_byte(c[8*k +: 8]);
            wait(response_ready);
            repeat(4) @(negedge clk);
        end
    endtask
    task check_reply_frame;
        reg [31:0] c,got;
        integer z;
        begin
            if(response[0]!=8'ha5 ||response[1]!=8'h5a ||
               response[2]!=2 ||
               {response[7],response[6],response[5],response[4]}
                   !=expected_session ||
               {response[11],response[10],response[9],response[8]}
                   !=expected_seq)
                $fatal(1,"bad reply envelope");
            c=32'hffffffff;
            for(z=2;z<response_total-4;z=z+1)
                c=crc_byte(c,response[z]);
            got={response[response_total-1],
                 response[response_total-2],
                 response[response_total-3],
                 response[response_total-4]};
            if(~c!=got) $fatal(1,"reply CRC %h != %h",~c,got);
        end
    endtask
    task expect_ack;
        input [7:0] kind;
        begin
            check_reply_frame();
            if(response[3]!=8'h80 || response[16]!=kind) begin
                $display("FAIL request %02h reply %02h payload %02h error %02h%02h",
                    kind,response[3],response[16],response[19],response[18]);
                $fatal(1);
            end
            if(kind==8'h10 || kind==8'h11)
                $display("ACK %02h next=%d gen=%d",kind,
                    response[36],dut.generation);
            case_count=case_count+1;
        end
    endtask
    task expect_error;
        input [7:0] kind;
        input [15:0] code;
        begin
            check_reply_frame();
            if(response[3]!=8'hff || response[16]!=kind ||
               {response[19],response[18]}!=code)
                $fatal(1,"expected ERROR %h/%h, got %h/%h",
                    kind,code,response[3],{response[19],response[18]});
            case_count=case_count+1;
        end
    endtask
    task make_song;
        input [7:0] unique_byte;
        integer k,s,base,off,len;
        reg [31:0] c;
        begin
            for(k=0;k<232;k=k+1) song[k]=0;
            song[0]="P";song[1]="S";song[2]="C";song[3]="2";
            song[4]=2;song_le32(8,232);
            for(k=0;k<16;k=k+1) song[12+k]=k+1;
            song[12]=unique_byte;
            song_le32(32,960);song[36]=4;song[38]=64;
            song[40]=64;song[44]=1;song[48]=1;
            song_le16(52,960);song_le16(54,120);
            song[192]="{";song[193]="}";
            song[194]=" ";song[195]=" ";
            song_le32(200,480);song[204]=60;song[205]=4;
            song[206]=2;song[207]=7;song_le32(208,1);
            song_le32(216,960);song[224]=4;song[225]=2;
            for(s=0;s<4;s=s+1) begin
                base=64+s*32;
                case(s)
                    0:begin song_le32(base,1);off=192;len=4;end
                    1:begin song_le32(base,2);off=196;len=16;end
                    2:begin song_le32(base,4);off=212;len=16;end
                    3:begin song_le32(base,8);off=228;len=4;end
                endcase
                song_le16(base+6,1);
                song_le32(base+8,off);
                song_le32(base+12,len);
                song_le32(base+16,1);
                song_le16(base+20,s==0 ? 0:len);
                c=32'hffffffff;
                for(k=off;k<off+len;k=k+1)
                    c=crc_byte(c,song[k]);
                song_le32(base+24,~c);
            end
        end
    endtask
    task make_begin;
        input [7:0] unique_byte;
        integer k;
        reg [31:0] c;
        begin
            make_song(unique_byte);
            for(k=0;k<16;k=k+1) payload[k]=song[12+k];
            c=32'hffffffff;
            for(k=0;k<232;k=k+1) c=crc_byte(c,song[k]);
            store_le32(16,232);store_le32(20,~c);
            payload[24]=0;payload[25]=2;
            payload[26]=2;payload[27]=0;
            store_le32(28,1);store_le32(32,1);
            payload[36]=3;payload[37]=0;
            payload[38]=0;payload[39]=0;
            payload[40]="O";payload[41]="n";payload[42]="e";
        end
    endtask
    task copy_data;
        input [7:0] unique_byte;
        integer k;
        begin
            make_song(unique_byte);
            for(k=0;k<16;k=k+1) payload[k]=song[12+k];
            store_le32(16,0);
            for(k=0;k<232;k=k+1) payload[20+k]=song[k];
        end
    endtask
    // The fake device models completed sector writes and reads; individual
    // block-level power-cut cases are covered by separate fault-injection tests.
    always @(posedge clk) begin
        dev_done<=0;dev_error<=0;
        if(dev_we && !dev_start) buffer[dev_addr]<=dev_wdata;
        if(dev_start) begin
            if(!dev_guard ||
               (fail_once && dev_write && dev_lba==fail_lba)) begin
                dev_error<=1;dev_done<=1;
                fail_once<=0;
            end else begin
                for(integer k=0;k<512;k=k+1) begin
                    if(dev_write) begin
                        if(dev_lba>=16384 && dev_lba<16392)
                            dir_a[(dev_lba-16384)*512+k]=buffer[k];
                        else if(dev_lba>=16392 && dev_lba<16400)
                            dir_b[(dev_lba-16392)*512+k]=buffer[k];
                        else if(dev_lba==32768) data0[k]=buffer[k];
                        else if(dev_lba==36864) log0[k]=buffer[k];
                        else if(dev_lba==40960) data1[k]=buffer[k];
                        else if(dev_lba==45056) log1[k]=buffer[k];
                    end else begin
                        if(dev_lba>=16384 && dev_lba<16392)
                            buffer[k]=dir_a[(dev_lba-16384)*512+k];
                        else if(dev_lba>=16392 && dev_lba<16400)
                            buffer[k]=dir_b[(dev_lba-16392)*512+k];
                        else if(dev_lba==32768) buffer[k]=data0[k];
                        else if(dev_lba==36864) buffer[k]=log0[k];
                        else if(dev_lba==40960) buffer[k]=data1[k];
                        else if(dev_lba==45056) buffer[k]=log1[k];
                        else buffer[k]=0;
                    end
                end
                dev_done<=1;
            end
        end
    end
    wire [7:0] received_byte;
    wire received_valid,framing_error;
    uart_rx #(.CLOCK_HZ(50_000_000),.BAUD(1_000_000)) reply_receiver (
        .clk(clk),.rst_n(rst_n),.rx(uart_tx),
        .data(received_byte),.valid(received_valid),
        .framing_error(framing_error)
    );
    always @(posedge clk) if(received_valid) begin
        response[response_count]<=received_byte;
        if(response_count==13)
            response_total<=16+{received_byte,response[12]}+4;
        response_count<=response_count+1'b1;
        if(response_total!=0 && response_count+1'b1==response_total)
            response_ready<=1;
    end
    initial begin
        for(i=0;i<4096;i=i+1) begin dir_a[i]=0;dir_b[i]=0; end
        for(i=0;i<512;i=i+1) begin
            buffer[i]=0;data0[i]=0;log0[i]=0;
            data1[i]=0;log1[i]=0;
        end
        dir_b[0]="P";dir_b[1]="S";dir_b[2]="D";dir_b[3]="L";
        dir_b[4]=1;dir_b[8]=4;
        crc=32'hffffffff;
        for(i=0;i<3584;i=i+1) crc=crc_byte(crc,dir_b[i]);
        crc=~crc;
        dir_b[3584]="P";dir_b[3585]="S";
        dir_b[3586]="D";dir_b[3587]="C";
        dir_b[3588]=4;
        for(i=0;i<4;i=i+1) begin
            dir_b[3592+i]=crc[8*i +: 8];
            dir_b[3596+i]=~crc[8*i +: 8];
        end
        repeat(5) @(negedge clk);rst_n=1;
        wait(storage_ready);
        @(negedge clk);page_request=1;
        @(negedge clk);page_request=0;
        wait(page_done);
        @(negedge clk);
        if(page_available || page_result!==4'd3)
            $fatal(1,"empty catalog page result=%0d available=%b",
                page_result,page_available);
        send_request(8'h01,32'd1,32'd1,0);expect_ack(8'h01);
        if(response[44]!=8) $fatal(1,"CAPS max_sections != 8");
`ifdef SINGLE_SLOT
        if(response[36]!=1 || response[40]!=1)
            $fatal(1,"CAPS slot limits != 1");
`endif
        make_begin(8'h11);
        send_request(8'h10,32'd1,32'd2,43);expect_ack(8'h10);
        copy_data(8'h11);
        send_request(8'h11,32'd1,32'd3,252);expect_ack(8'h11);
        // A reboot must recover block 0 from the verified data + log pair.
        @(negedge clk);rst_n=0;
        repeat(5) @(negedge clk);rst_n=1;
        wait(storage_ready);
        $display("RECOVER: next=%d epoch=%h log=%h %h %h %h data=%h",
            dut.entry_next[0],dut.entry_epoch[0],
            log0[0],log0[1],log0[2],log0[3],data0[0]);
        send_request(8'h01,32'd2,32'd1,0);expect_ack(8'h01);
        make_begin(8'h11);
        send_request(8'h10,32'd2,32'd2,43);expect_ack(8'h10);
        if(response[36]!=1) $fatal(1,"resume next_block != 1");
        for(i=0;i<16;i=i+1) payload[i]=song[12+i];
        store_le32(16,232);
        crc=32'hffffffff;
        for(i=0;i<232;i=i+1) crc=crc_byte(crc,song[i]);
        store_le32(20,~crc);
        send_request(8'h12,32'd2,32'd3,24);expect_ack(8'h12);
`ifdef SINGLE_SLOT
        // A complete song occupies the only slot until an explicit DELETE.
        make_begin(8'h22);
        send_request(8'h10,32'd2,32'd4,43);
        expect_error(8'h10,16'h0002);
        store_le32(0,0);store_le32(4,0);
        payload[8]=1;payload[9]=0;payload[10]=0;payload[11]=0;
        send_request(8'h03,32'd2,32'd5,12);expect_ack(8'h03);
        if(response[28]!=1 || response[32]!=8'h11)
            $fatal(1,"single-slot LIST incorrect");
        if(response[76]!="O" || response[77]!="n" || response[78]!="e")
            $fatal(1,"single-slot LIST title corrupted: %h %h %h",
                response[76],response[77],response[78]);
        for(i=0;i<16;i=i+1) payload[i]=i+1;
        payload[0]=8'h11;
        send_request(8'h14,32'd2,32'd6,16);expect_ack(8'h14);
        make_begin(8'h22);
        send_request(8'h10,32'd2,32'd7,43);expect_ack(8'h10);
        $display("PASS score_store_v2 single slot: resume, commit, full, list, delete, replace");
        $finish;
`else
        make_begin(8'h22);
        send_request(8'h10,32'd2,32'd4,43);expect_ack(8'h10);
        copy_data(8'h22);
        send_request(8'h11,32'd2,32'd5,252);expect_ack(8'h11);
        send_request(8'h11,32'd2,32'd5,252);expect_ack(8'h11);
        // A forged same-sequence request must not evict the prior reply.
        payload[20]=payload[20]^8'h01;
        send_request(8'h11,32'd2,32'd5,252);
        expect_error(8'h11,16'h000d);
        payload[20]=payload[20]^8'h01;
        send_request(8'h11,32'd2,32'd5,252);expect_ack(8'h11);
        send_request(8'h11,32'd2,32'd6,252);expect_ack(8'h11);
        payload[20]=payload[20]^8'h01;
        send_request(8'h11,32'd2,32'd7,252);
        expect_error(8'h11,16'h0009);
        payload[20]=payload[20]^8'h01;
        for(i=0;i<16;i=i+1) payload[i]=song[12+i];
        store_le32(16,232);
        crc=32'hffffffff;
        for(i=0;i<232;i=i+1) crc=crc_byte(crc,song[i]);
        store_le32(20,~crc);
        send_request(8'h12,32'd2,32'd8,24);expect_ack(8'h12);
        store_le32(0,0);store_le32(4,0);
        payload[8]=1;payload[9]=0;payload[10]=0;payload[11]=0;
        send_request(8'h03,32'd2,32'd9,12);expect_ack(8'h03);
        if(response[28]!=1) $fatal(1,"LIST count != 1");
        if(response[32]!=8'h11) $fatal(1,"LIST first UUID incorrect");
        if(response[76]!="O" || response[77]!="n" || response[78]!="e")
            $fatal(1,"LIST title corrupted: %h %h %h",
                response[76],response[77],response[78]);
        store_le32(0,catalog_generation);store_le32(4,1);
        send_request(8'h03,32'd2,32'd10,12);
        expect_ack(8'h03);
        if(response[28]!=1 ||response[32]!=8'h22)
            $fatal(1,"LIST second UUID incorrect");
        for(i=0;i<16;i=i+1) payload[i]=i+1;
        payload[0]=8'h11;
        send_request(8'h14,32'd2,32'd11,16);expect_ack(8'h14);
        if(response[36]!=1) $fatal(1,"DELETE did not delete");
        store_le32(0,0);store_le32(4,0);
        payload[8]=1;payload[9]=0;payload[10]=0;payload[11]=0;
        send_request(8'h03,32'd2,32'd12,12);expect_ack(8'h03);
        if(response[28]!=1 ||response[32]!=8'h22)
            $fatal(1,"LIST after hole incorrect");
        if(case_count!=18) $fatal(1,"case count %d",case_count);
        // Failed inactive-copy publication must leave the older committed
        // generation mountable after a power cycle.
        make_begin(8'h33);
        fail_lba=16392;fail_once=1;
        send_request(8'h10,32'd2,32'd13,43);
        expect_error(8'h10,16'h0008);
        @(negedge clk);rst_n=0;
        repeat(5) @(negedge clk);rst_n=1;
        wait(storage_ready);
        if(catalog_generation!=9)
            $fatal(1,"rollback generation %d",catalog_generation);
        send_request(8'h01,32'd3,32'd1,0);expect_ack(8'h01);
        store_le32(0,0);store_le32(4,0);
        payload[8]=1;payload[9]=0;payload[10]=0;payload[11]=0;
        send_request(8'h03,32'd3,32'd2,12);expect_ack(8'h03);
        if(response[28]!=1 ||response[32]!=8'h22)
            $fatal(1,"LIST after publish failure incorrect");
        $display("PASS score_store_v2: two songs, reboot resume, COMMIT, LIST, DELETE, failed publish rollback (%d replies)",case_count);
        $finish;
`endif
    end
    initial begin
        #2000000000;
        $fatal(1,"timeout state=%d owner=%d gen=%d req=%h",
            dut.state,dut.owner,dut.generation,dut.held_req_type);
    end
endmodule
