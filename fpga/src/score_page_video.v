// Display the packed 640x480 MONO1 page. One synchronous
// RAM-read cycle is exposed at this interface; the caller delays its other
// RGB paths and HDMI control signals by the same extra pixel clock.
module score_page_video (
    input wire pixel_clk,pixel_rst_n,de,
    input wire [9:0] pix_x,pix_y,
    input wire page_ready,
    input wire [7:0] page_byte,
    output wire [15:0] page_addr,
    output wire [23:0] rgb
);
    wire [16:0] row_offset=({7'd0,pix_y}<<6)+
                            ({7'd0,pix_y}<<4);
    assign page_addr=row_offset[15:0]+{9'd0,pix_x[9:3]};
    reg [2:0] bit_pos_q;
    reg de_q;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            bit_pos_q<=0;de_q<=0;
        end else begin
            bit_pos_q<=3'd7-pix_x[2:0];
            de_q<=de;
        end
    end
    assign rgb=!de_q ? 24'h000000 :
               !page_ready ? 24'h14213D :
               page_byte[bit_pos_q] ? 24'h101828 : 24'hF8FAFC;
endmodule
