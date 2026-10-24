`timescale 1ns/1ps
module tb_sd_spi_block_device;
    reg clk=0, rst_n=0, miso=1;
    always #10 clk=~clk;
    wire cs_n, sck, mosi, ready, init_done, done;
    wire [7:0] error_code, buffer_rdata;
    wire [31:0] sector_count;
    reg req_start=0, req_write=0, req_guard_valid=0;
    reg [31:0] req_lba=0;
    reg [8:0] buffer_addr=0;
    reg [7:0] buffer_wdata=0;
    reg buffer_we=0;
    sd_spi_block_device dut(clk,rst_n,miso,cs_n,sck,mosi,
        req_start,req_write,req_guard_valid,req_lba,ready,init_done,done,
        error_code,sector_count,buffer_addr,buffer_wdata,buffer_we,buffer_rdata);

    reg [7:0] q[0:2047], card_data[0:511], cmd_buf[0:5];
    integer qr=0,qw=0,bit_no=0,cmd_no=0,write_no=-1;
    reg [7:0] rx_shift=0;
    reg [31:0] card_lba=0;
    reg bad_crc=0;
    reg suppress_cmd17=0;
    reg reject_write=0, corrupt_readback=0;
    reg [15:0] card_write_crc=0;
    reg [7:0] card_write_crc_hi=0;
    integer reads=0,writes=0;
    integer i;
    reg [15:0] crc;
    function [15:0] crc_step;
        input [15:0] old_crc;
        input [7:0] value;
        integer k;
        reg [15:0] c;
        begin
            c=old_crc;
            for(k=7;k>=0;k=k-1)
                c=c[15]^value[k] ? {c[14:0],1'b0}^16'h1021 : {c[14:0],1'b0};
            crc_step=c;
        end
    endfunction
    task push;
        input [7:0] value;
        begin q[qw]=value; qw=qw+1; end
    endtask
    task send_block;
        input integer csd;
        reg [7:0] value;
        begin
            push(8'hfe); crc=0;
            for(i=0;i<(csd ? 16 : 512);i=i+1) begin
                value=csd ? ((i==0) ? 8'h40 : (i==9) ? 8'd31 : 8'h00) : card_data[i];
                push(value); crc=crc_step(crc,value);
            end
            push(crc[15:8] ^ (bad_crc ? 8'h01 : 8'h00)); push(crc[7:0]);
        end
    endtask
    task command_reply;
        input [7:0] number;
        begin
            case(number)
                0: push(8'h01);
                8: begin push(8'h01); push(0); push(0); push(8'h01); push(8'haa); end
                55: push(8'h01);
                41: push(8'h00);
                58: begin push(0); push(8'h40); push(8'hff); push(8'h80); push(0); end
                9: begin push(0); send_block(1); end
                17: begin reads=reads+1; if(!suppress_cmd17) begin push(0); send_block(0); end end
                24: begin writes=writes+1; push(0); write_no=0; end
                default: begin $display("unexpected CMD%0d",number); $fatal; end
            endcase
        end
    endtask
    // The card samples MOSI on rising edges and changes MISO on falling edges.
    // Queue entries are complete response bytes, never forced DUT internals.
    always @(negedge sck) begin
        if (!cs_n) miso = (qr<qw) ? q[qr][7-bit_no] : 1'b1;
        else miso=1;
    end
    always @(posedge sck) begin : card_receive
        reg [7:0] incoming;
        if (!cs_n) begin
            incoming={rx_shift[6:0],mosi};
            rx_shift=incoming;
            if(bit_no==7) begin
                bit_no=0;
                if(qr<qw) qr=qr+1;
                if(write_no>=0) begin
                    if(write_no==0) begin
                        if(incoming==8'hfe) begin write_no=1; card_write_crc=0; end
                    end else if(write_no<=512) begin
                        card_data[write_no-1]=incoming; write_no=write_no+1;
                        card_write_crc=crc_step(card_write_crc,incoming);
                    end else if(write_no==513) begin
                        card_write_crc_hi=incoming; write_no=514;
                    end else if(write_no==514) begin
                        write_no=-1;
                        if({card_write_crc_hi,incoming}!=card_write_crc)
                            $fatal(1,"DUT transmitted wrong write CRC");
                        push(reject_write ? 8'h0d : 8'h05);
                        push(0); push(8'hff);
                        if(corrupt_readback) card_data[511]=card_data[511]^8'h01;
                    end else write_no=write_no+1;
                end else if(cmd_no!=0 || incoming[7:6]==2'b01) begin
                    cmd_buf[cmd_no]=incoming;
                    if(cmd_no==5) begin
                        cmd_no=0;
                        card_lba={cmd_buf[1],cmd_buf[2],cmd_buf[3],cmd_buf[4]};
                        command_reply(cmd_buf[0][5:0]);
                    end else cmd_no=cmd_no+1;
                end
            end else bit_no=bit_no+1;
        end
    end
    always @(posedge cs_n) begin
        bit_no=0; cmd_no=0; rx_shift=0;
        qr=0; qw=0;
    end
    task wait_done;
        integer timeout;
        begin
            timeout=0;
            while(!done && timeout<2000000) begin @(posedge clk); timeout=timeout+1; end
            if(!done) begin $display("timeout state=%0d cmd=%0d err=%h",dut.state,dut.command,error_code); $fatal; end
            @(posedge clk);
        end
    endtask
    task request;
        input wr, guard;
        input [31:0] lba;
        begin
            @(negedge clk); req_write=wr; req_guard_valid=guard; req_lba=lba; req_start=1;
            @(negedge clk); req_start=0;
            wait_done();
        end
    endtask
    initial begin
        for(i=0;i<512;i=i+1) card_data[i]=i[7:0];
        repeat(4) @(negedge clk); rst_n=1;
        wait(init_done || error_code!=0);
        if(!init_done || error_code || sector_count!=32'd32768) begin
            $display("init failed state=%0d err=%h sectors=%0d",dut.state,error_code,sector_count); $fatal;
        end
        request(0,1,32'd8192);
        if(error_code || buffer_rdata!==0 || reads!=1) $fatal(1,"read failed err=%h",error_code);
        @(negedge clk); buffer_addr=9'd255; #1;
        if(buffer_rdata!==8'hff) $fatal(1,"read data wrong");
        request(0,0,32'd8192);
        if(error_code!=8'h40 || reads!=1) $fatal(1,"guard failure");
        request(0,1,32'd32768);
        if(error_code!=8'h40 || reads!=1) $fatal(1,"range failure");
        for(i=0;i<512;i=i+1) begin
            @(negedge clk); buffer_addr=i; buffer_wdata=8'h80 ^ i[7:0]; buffer_we=1;
        end
        @(negedge clk); buffer_we=0;
        request(1,1,32'd8192);
        if(error_code || writes!=1 || reads!=2) $fatal(1,"write/readback failed err=%h",error_code);
        @(negedge clk); buffer_addr=0; #1;
        if(buffer_rdata!==8'h80) $fatal(1,"write buffer first byte changed");
        @(negedge clk); buffer_addr=511; #1;
        if(buffer_rdata!==(8'h80 ^ 8'hff)) $fatal(1,"write buffer last byte changed");
        bad_crc=1;
        request(0,1,32'd8192);
        if(error_code!=8'h31) $fatal(1,"CRC fault not detected err=%h",error_code);
        @(negedge clk); rst_n=0; bad_crc=0; suppress_cmd17=1;
        repeat(4) @(negedge clk); rst_n=1;
        wait(init_done || error_code!=0);
        if(!init_done || error_code) $fatal(1,"reinit failed");
        request(0,1,32'd8192);
        if(error_code!=8'h12) $fatal(1,"response timeout not detected err=%h",error_code);
        @(negedge clk); rst_n=0; suppress_cmd17=0; reject_write=1;
        repeat(4) @(negedge clk); rst_n=1;
        wait(init_done || error_code!=0);
        if(!init_done || error_code) $fatal(1,"reinit for rejection failed");
        request(1,1,32'd8192);
        if(error_code!=8'h61) $fatal(1,"write rejection not detected err=%h",error_code);
        @(negedge clk); rst_n=0; reject_write=0; corrupt_readback=1;
        repeat(4) @(negedge clk); rst_n=1;
        wait(init_done || error_code!=0);
        if(!init_done || error_code) $fatal(1,"reinit for mismatch failed");
        request(1,1,32'd8192);
        if(error_code!=8'h51) $fatal(1,"readback mismatch not detected err=%h",error_code);
        $display("PASS sd_spi_block_device init/read/guard/write-readback/boundaries/CRC/timeout/reject/mismatch");
        $finish;
    end
    initial begin #200000000; $fatal(1,"global timeout state=%0d cmd=%0d",dut.state,dut.command); end
endmodule
