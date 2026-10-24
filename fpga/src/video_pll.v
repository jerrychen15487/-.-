// 50 MHz -> 25 MHz pixel clock and 125 MHz OSER10 fast clock.
// A 750 MHz VCO is divided by 30 and 6 respectively.
module video_pll (
    input  wire clk_in,
    input  wire reset,
    output wire pixel_clk,
    output wire serial_clk,
    output wire locked
);
    wire clkout2, clkout3, clkout4, clkout5, clkout6;
    wire clkfbout;
    wire [7:0] mdrdo;
    wire gnd = 1'b0;

    PLLA u_plla (
        .CLKOUT0(pixel_clk), .CLKOUT1(serial_clk),
        .CLKOUT2(clkout2), .CLKOUT3(clkout3), .CLKOUT4(clkout4),
        .CLKOUT5(clkout5), .CLKOUT6(clkout6), .CLKFBOUT(clkfbout),
        .MDRDO(mdrdo), .LOCK(locked),
        .CLKIN(clk_in), .CLKFB(gnd),
        .PSSEL(3'b000), .PSDIR(gnd), .PSPULSE(gnd),
        .SSCPOL(gnd), .SSCON(gnd), .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0), .MDWDI(8'b0), .MDCLK(gnd),
        .MDOPC(2'b00), .MDAINC(gnd), .RESET(reset), .PLLPWD(gnd),
        .RESET_I(gnd), .RESET_O(gnd)
    );

    defparam u_plla.FCLKIN = "50";
    defparam u_plla.IDIV_SEL = 1;
    defparam u_plla.FBDIV_SEL = 1;
    defparam u_plla.MDIV_SEL = 15;
    defparam u_plla.MDIV_FRAC_SEL = 0;
    defparam u_plla.ODIV0_SEL = 30;
    defparam u_plla.ODIV0_FRAC_SEL = 0;
    defparam u_plla.ODIV1_SEL = 6;
    defparam u_plla.CLKOUT0_EN = "TRUE";
    defparam u_plla.CLKOUT1_EN = "TRUE";
    defparam u_plla.CLKOUT2_EN = "FALSE";
    defparam u_plla.CLKOUT3_EN = "FALSE";
    defparam u_plla.CLKOUT4_EN = "FALSE";
    defparam u_plla.CLKOUT5_EN = "FALSE";
    defparam u_plla.CLKOUT6_EN = "FALSE";
    defparam u_plla.CLKFB_SEL = "INTERNAL";
endmodule
