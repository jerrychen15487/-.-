// Framing-only UART v2 transport. A verified request is held until the
// command layer supplies one reply. No storage semantics live here.
module score_uart_v2_transport (
    input wire clk, rst_n, rx,
    output wire tx,
    output reg request_valid,
    output reg crc_error_pulse,
    output reg [7:0] request_type,
    output reg [31:0] request_session, request_seq,
    output reg [10:0] request_len,
    input wire [9:0] request_addr,
    output reg [7:0] request_byte,
    input wire reply_valid,
    input wire [7:0] reply_type,
    input wire [10:0] reply_len,
    output reg [9:0] reply_addr,
    input wire [7:0] reply_byte,
    output reg reply_done
);
    wire [7:0] rx_byte;
    wire rx_valid, framing_error;
    uart_rx #(.CLOCK_HZ(50_000_000),.BAUD(1_000_000)) receiver (
        .clk(clk),.rst_n(rst_n),.rx(rx),.data(rx_byte),
        .valid(rx_valid),.framing_error(framing_error)
    );
    reg tx_start;
    reg [7:0] tx_byte;
    wire tx_ready;
    score_uart_tx #(.CLOCK_HZ(50_000_000),.BAUD(1_000_000)) sender (
        .clk(clk),.rst_n(rst_n),.start(tx_start),.data(tx_byte),
        .ready(tx_ready),.tx(tx)
    );
    reg [7:0] payload_mem[0:1023];
    // Registered read permits block-RAM inference and separates address
    // selection from command decoding. The caller waits one clock per read.
    always @(posedge clk)
        request_byte<=payload_mem[request_addr];
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] octet;
        reg [31:0] c;
        integer i;
        begin
            c=previous^{24'd0,octet};
            for(i=0;i<8;i=i+1)
                c=c[0] ? ((c>>1)^32'hedb88320) : (c>>1);
            crc_byte=c;
        end
    endfunction
    localparam RECEIVE=0,WAIT_REPLY=1,PREPARE_GET=2,
        PREPARE_CRC=3,SEND_GET=4,SEND_WAIT=5,
        PREPARE_PREFETCH=6,SEND_PREFETCH=7,
        PREPARE_LATCH=8,SEND_LATCH=9;
    reg [3:0] state;
    reg [10:0] pos,crc_pos,send_pos;
    reg [15:0] payload_len;
    reg [31:0] received_crc,running_crc,send_crc;
    reg [22:0] gap_ticks;
    reg [7:0] held_reply_type;
    reg [10:0] held_reply_len;
    reg [7:0] crc_data,send_data,reply_byte_q;
    wire [10:0] wire_pos=(state==PREPARE_PREFETCH ||
        state==PREPARE_LATCH ||
        state==PREPARE_GET ||
        state==PREPARE_CRC) ? crc_pos : send_pos;
    // Issue the next payload address at the CRC/TX step boundary. The
    // existing PREFETCH and LATCH states then give the directory BSRAM its
    // read cycle without a state -> address -> reply-byte combinational path.
    reg [7:0] wire_byte;
    always @* begin
        wire_byte=0;
        case(wire_pos)
            0:wire_byte=8'ha5;
            1:wire_byte=8'h5a;
            2:wire_byte=8'h02;
            3:wire_byte=held_reply_type;
            4:wire_byte=request_session[7:0];
            5:wire_byte=request_session[15:8];
            6:wire_byte=request_session[23:16];
            7:wire_byte=request_session[31:24];
            8:wire_byte=request_seq[7:0];
            9:wire_byte=request_seq[15:8];
            10:wire_byte=request_seq[23:16];
            11:wire_byte=request_seq[31:24];
            12:wire_byte=held_reply_len[7:0];
            13:wire_byte={5'd0,held_reply_len[10:8]};
            14,15:wire_byte=0;
            default: begin
                if(wire_pos>=11'd16 && wire_pos<11'd16+held_reply_len)
                    wire_byte=reply_byte_q;
                else if(wire_pos==11'd16+held_reply_len)
                    wire_byte=~send_crc[7:0];
                else if(wire_pos==11'd17+held_reply_len)
                    wire_byte=~send_crc[15:8];
                else if(wire_pos==11'd18+held_reply_len)
                    wire_byte=~send_crc[23:16];
                else if(wire_pos==11'd19+held_reply_len)
                    wire_byte=~send_crc[31:24];
            end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=RECEIVE; pos<=0; crc_pos<=0; send_pos<=0;
            payload_len<=0; request_type<=0; request_session<=0;
            request_seq<=0; request_len<=0; received_crc<=0;
            running_crc<=32'hffffffff; send_crc<=32'hffffffff;
            gap_ticks<=0; held_reply_type<=0; held_reply_len<=0;
            crc_data<=0;send_data<=0;reply_byte_q<=0;reply_addr<=0;
            tx_start<=0; tx_byte<=0; request_valid<=0;
            crc_error_pulse<=0; reply_done<=0;
        end else begin
            tx_start<=0; request_valid<=0;
            crc_error_pulse<=0; reply_done<=0;
            case(state)
                RECEIVE: begin
                    if(framing_error) begin pos<=0; gap_ticks<=0; end
                    else if(rx_valid) begin
                        gap_ticks<=0;
                        if(pos==0) begin
                            if(rx_byte==8'ha5) pos<=1;
                        end else if(pos==1) begin
                            if(rx_byte==8'h5a) begin
                                pos<=2; running_crc<=32'hffffffff;
                                received_crc<=0; payload_len<=0;
                                request_session<=0; request_seq<=0;
                            end else pos<=(rx_byte==8'ha5) ? 1 : 0;
                        end else if(pos==2 && rx_byte!=8'h02)
                            pos<=(rx_byte==8'ha5) ? 1 : 0;
                        else if((pos==14 && rx_byte!=0) ||
                                (pos==15 && (rx_byte!=0 || payload_len>1024)))
                            pos<=(rx_byte==8'ha5) ? 1 : 0;
                        else begin
                            if(pos<16+payload_len)
                                running_crc<=crc_byte(running_crc,rx_byte);
                            case(pos)
                                3:request_type<=rx_byte;
                                4:request_session[7:0]<=rx_byte;
                                5:request_session[15:8]<=rx_byte;
                                6:request_session[23:16]<=rx_byte;
                                7:request_session[31:24]<=rx_byte;
                                8:request_seq[7:0]<=rx_byte;
                                9:request_seq[15:8]<=rx_byte;
                                10:request_seq[23:16]<=rx_byte;
                                11:request_seq[31:24]<=rx_byte;
                                12:payload_len[7:0]<=rx_byte;
                                13:payload_len[15:8]<=rx_byte;
                                default:begin end
                            endcase
                            if(pos>=16 && pos<16+payload_len)
                                payload_mem[pos-16]<=rx_byte;
                            if(pos>=16+payload_len && pos<19+payload_len)
                                received_crc<={rx_byte,received_crc[31:8]};
                            if(pos==19+payload_len) begin
                                pos<=0;
                                if({rx_byte,received_crc[31:8]}==~running_crc) begin
                                    if(request_session!=0 && request_seq!=0 &&
                                       request_type!=8'h80 &&
                                       request_type!=8'h90 &&
                                       request_type!=8'hff) begin
                                        request_len<=payload_len[10:0];
                                        request_valid<=1;
                                        state<=WAIT_REPLY;
                                    end
                                end else crc_error_pulse<=1;
                            end else pos<=pos+1'b1;
                        end
                    end else if(pos!=0) begin
                        if(gap_ticks==23'd4999999) begin
                            pos<=0; gap_ticks<=0;
                        end else gap_ticks<=gap_ticks+1'b1;
                    end
                end
                WAIT_REPLY: if(reply_valid) begin
                    held_reply_type<=reply_type;
                    held_reply_len<=reply_len;
                    crc_pos<=2; send_crc<=32'hffffffff;
                    reply_addr<=0;
                    state<=PREPARE_PREFETCH;
                end
                // The directory title is read from synchronous BSRAM. Let its
                // output update before latching the reply byte for CRC/TX.
                PREPARE_PREFETCH:state<=PREPARE_LATCH;
                PREPARE_LATCH:begin
                    reply_byte_q<=reply_byte;
                    state<=PREPARE_GET;
                end
                PREPARE_GET:begin
                    crc_data<=wire_byte;
                    state<=PREPARE_CRC;
                end
                PREPARE_CRC: begin
                    send_crc<=crc_byte(send_crc,crc_data);
                    if(crc_pos==11'd15+held_reply_len) begin
                        send_pos<=0; reply_addr<=0;
                        state<=SEND_PREFETCH;
                    end else begin
                        crc_pos<=crc_pos+1'b1;
                        reply_addr<=(crc_pos>=11'd15 &&
                                     crc_pos<11'd1039) ?
                            crc_pos[9:0]-10'd15 : 10'd0;
                        state<=PREPARE_PREFETCH;
                    end
                end
                SEND_PREFETCH:state<=SEND_LATCH;
                SEND_LATCH:begin
                    reply_byte_q<=reply_byte;
                    state<=SEND_GET;
                end
                SEND_GET:begin
                    if(send_pos<11'd20+held_reply_len) begin
                        send_data<=wire_byte;
                        state<=SEND_WAIT;
                    end else begin
                        reply_done<=1;state<=RECEIVE;
                    end
                end
                SEND_WAIT:if(tx_ready && !tx_start) begin
                        tx_byte<=send_data; tx_start<=1;
                        send_pos<=send_pos+1'b1;
                        reply_addr<=(send_pos>=11'd15 &&
                                     send_pos<11'd1039) ?
                            send_pos[9:0]-10'd15 : 10'd0;
                        state<=SEND_PREFETCH;
                end
                default:state<=RECEIVE;
            endcase
        end
    end
endmodule
