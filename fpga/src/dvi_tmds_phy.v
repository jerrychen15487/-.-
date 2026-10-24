module dvi_tmds_lane (
    input  wire       pixel_clk,
    input  wire       serial_clk,
    input  wire       rst_n,
    input  wire [9:0] symbol,
    output wire       out_p,
    output wire       out_n
);
    reg reset_pixel;
    wire serial_data;

    // OSER10 has an active-high asynchronous reset.  Match Gowin's Tang 60K
    // HDMI reference structure: assert asynchronously, release on PCLK.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n)
            reset_pixel <= 1'b1;
        else
            reset_pixel <= 1'b0;
    end

    OSER10 u_oser10 (
        .Q(serial_data),
        .D0(symbol[0]), .D1(symbol[1]), .D2(symbol[2]), .D3(symbol[3]),
        .D4(symbol[4]), .D5(symbol[5]), .D6(symbol[6]), .D7(symbol[7]),
        .D8(symbol[8]), .D9(symbol[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(reset_pixel)
    );
    ELVDS_OBUF u_diff_out (.I(serial_data), .O(out_p), .OB(out_n));
endmodule

module dvi_clock_lane (
    input  wire pixel_clk,
    output wire out_p,
    output wire out_n
);
    ELVDS_OBUF u_diff_clk (.I(pixel_clk), .O(out_p), .OB(out_n));
endmodule
