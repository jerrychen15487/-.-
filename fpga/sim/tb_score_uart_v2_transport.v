`timescale 1ns/1ps
module tb_score_uart_v2_transport;
    reg clk=0,rst_n=0,rx=1;
    always #10 clk=~clk;
    wire tx,request_valid,crc_error_pulse,reply_done;
    wire [7:0] request_type,request_byte;
    wire [31:0] request_session,request_seq;
    wire [10:0] request_len;
    wire [9:0] reply_addr;
    reg reply_valid=0;
    wire [7:0] reply_byte=(reply_addr==0) ? 8'h01 :
        (reply_addr==2) ? 8'h08 :
        (reply_addr>=4) ? 8'hff : 8'h00;
    wire [7:0] captured;
    wire captured_valid,captured_framing;
    reg [7:0] response[0:27];
    integer count=0,requests=0,crc_errors=0,i;
    score_uart_v2_transport dut (
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),
        .request_valid(request_valid),.crc_error_pulse(crc_error_pulse),
        .request_type(request_type),.request_session(request_session),
        .request_seq(request_seq),.request_len(request_len),
        .request_addr(10'd0),.request_byte(request_byte),
        .reply_valid(reply_valid),.reply_type(8'hff),.reply_len(11'd8),
        .reply_addr(reply_addr),.reply_byte(reply_byte),.reply_done(reply_done)
    );
    uart_rx #(.CLOCK_HZ(50_000_000),.BAUD(1_000_000)) capture (
        .clk(clk),.rst_n(rst_n),.rx(tx),.data(captured),
        .valid(captured_valid),.framing_error(captured_framing)
    );
    always @(posedge clk) if(rst_n) begin
        if(request_valid) begin
            requests=requests+1;
            if(request_type!=1 || request_session!=1 || request_seq!=1 ||
               request_len!=0) $fatal(1,"bad CAPS decode");
            reply_valid<=1;
        end else reply_valid<=0;
        if(crc_error_pulse) crc_errors=crc_errors+1;
        if(captured_valid) begin
            if(count>=28) $fatal(1,"extra response byte");
            response[count]=captured; count=count+1;
        end
        if(captured_framing) $fatal(1,"response UART framing error");
    end
    task send_byte;
        input [7:0] value;
        integer bit_no,k;
        begin
            rx=0; repeat(50) @(negedge clk);
            for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin
                rx=value[bit_no];
                repeat(50) @(negedge clk);
            end
            rx=1; repeat(50) @(negedge clk);
        end
    endtask
    task send_caps;
        input corrupt;
        begin
            send_byte(8'ha5); send_byte(8'h5a); send_byte(8'h02);
            send_byte(8'h01); send_byte(8'h01);
            for(i=0;i<3;i=i+1) send_byte(0);
            send_byte(8'h01);
            for(i=0;i<7;i=i+1) send_byte(0);
            send_byte(corrupt ? 8'h1f : 8'h1e);
            send_byte(8'h28); send_byte(8'h4c); send_byte(8'hba);
        end
    endtask
    initial begin
        repeat(10) @(negedge clk); rst_n=1;
        send_caps(1);
        repeat(100) @(negedge clk);
        if(crc_errors!=1 || requests!=0 || count!=0)
            $fatal(1,"bad CRC not rejected");
        send_caps(0);
        wait(reply_done);
        repeat(600) @(negedge clk);
        if(requests!=1 || count!=28 || response[0]!=8'ha5 ||
           response[1]!=8'h5a || response[2]!=8'h02 ||
           response[3]!=8'hff || response[12]!=8'd8 ||
           response[16]!=1 || response[18]!=8 || response[23]!=8'hff)
            $fatal(1,"reply framing/semantic mismatch requests=%0d bytes=%0d",requests,count);
        $display("PASS score_uart_v2_transport CRC/reject/request/reply");
        $finish;
    end
    initial begin
        repeat(200000) @(negedge clk);
        $fatal(1,"timeout requests=%0d crc_errors=%0d bytes=%0d pos=%0d state=%0d",
            requests,crc_errors,count,dut.pos,dut.state);
    end
endmodule
