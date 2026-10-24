// DVI 1.0 TMDS encoder. Bit 0 is serialized first by OSER10.
module dvi_tmds_encoder (
    input  wire       pixel_clk,
    input  wire       rst_n,
    input  wire       de,
    input  wire [7:0] data,
    input  wire       c0,
    input  wire       c1,
    output reg  [9:0] tmds
);
    wire [3:0] data_ones = data[0] + data[1] + data[2] + data[3] +
                           data[4] + data[5] + data[6] + data[7];
    wire use_xnor = (data_ones > 4) || ((data_ones == 4) && !data[0]);
    wire [8:0] qm;
    assign qm[0] = data[0];
    assign qm[1] = use_xnor ? ~(qm[0] ^ data[1]) : (qm[0] ^ data[1]);
    assign qm[2] = use_xnor ? ~(qm[1] ^ data[2]) : (qm[1] ^ data[2]);
    assign qm[3] = use_xnor ? ~(qm[2] ^ data[3]) : (qm[2] ^ data[3]);
    assign qm[4] = use_xnor ? ~(qm[3] ^ data[4]) : (qm[3] ^ data[4]);
    assign qm[5] = use_xnor ? ~(qm[4] ^ data[5]) : (qm[4] ^ data[5]);
    assign qm[6] = use_xnor ? ~(qm[5] ^ data[6]) : (qm[5] ^ data[6]);
    assign qm[7] = use_xnor ? ~(qm[6] ^ data[7]) : (qm[6] ^ data[7]);
    assign qm[8] = ~use_xnor;
    wire [3:0] qm_ones = qm[0] + qm[1] + qm[2] + qm[3] +
                         qm[4] + qm[5] + qm[6] + qm[7];
    wire signed [5:0] balance = $signed({1'b0, qm_ones, 1'b0}) - 6'sd8;
    reg signed [6:0] disparity;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            tmds <= 10'b1101010100;
            disparity <= 7'sd0;
        end else if (!de) begin
            case ({c1, c0})
                2'b00: tmds <= 10'b1101010100;
                2'b01: tmds <= 10'b0010101011;
                2'b10: tmds <= 10'b0101010100;
                default: tmds <= 10'b1010101011;
            endcase
            disparity <= 7'sd0;
        end else if ((balance == 0) || (disparity == 0)) begin
            tmds[9] <= ~qm[8];
            tmds[8] <= qm[8];
            tmds[7:0] <= qm[8] ? qm[7:0] : ~qm[7:0];
            disparity <= qm[8] ? disparity + balance : disparity - balance;
        end else if (((disparity > 0) && (balance > 0)) ||
                     ((disparity < 0) && (balance < 0))) begin
            tmds[9] <= 1'b1;
            tmds[8] <= qm[8];
            tmds[7:0] <= ~qm[7:0];
            disparity <= disparity - balance + (qm[8] ? 7'sd2 : 7'sd0);
        end else begin
            tmds[9] <= 1'b0;
            tmds[8] <= qm[8];
            tmds[7:0] <= qm[7:0];
            disparity <= disparity + balance - (qm[8] ? 7'sd0 : 7'sd2);
        end
    end
endmodule
