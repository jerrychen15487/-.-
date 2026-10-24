`timescale 1ns/1ps
// Persistent onset-result counters in the practice header. These are counts,
// not the four-dimension final F5 score. P/G/M/X stand for Perfect, Good,
// Miss, and extra wrong notes; each count saturates at 99 in the source.
module practice_stats_video (
    input wire de,
    input wire [9:0] x,y,
    input wire [6:0] perfect_count,good_count,miss_count,wrong_count,
    output wire pixel_on,
    output reg [23:0] pixel_rgb
);
    wire p_digit,g_digit,m_digit,x_digit;
    practice_combo_video #(.X0(10'd135)) u_p (
        .de(de),.x(x),.y(y),.combo(perfect_count),.pixel_on(p_digit));
    practice_combo_video #(.X0(10'd210)) u_g (
        .de(de),.x(x),.y(y),.combo(good_count),.pixel_on(g_digit));
    practice_combo_video #(.X0(10'd285)) u_m (
        .de(de),.x(x),.y(y),.combo(miss_count),.pixel_on(m_digit));
    practice_combo_video #(.X0(10'd360)) u_x (
        .de(de),.x(x),.y(y),.combo(wrong_count),.pixel_on(x_digit));
    wire p_label=letter_pixel(2'd0,10'd115,x,y,de);
    wire g_label=letter_pixel(2'd1,10'd190,x,y,de);
    wire m_label=letter_pixel(2'd2,10'd265,x,y,de);
    wire x_label=letter_pixel(2'd3,10'd340,x,y,de);
    assign pixel_on=p_digit || g_digit || m_digit || x_digit ||
        p_label || g_label || m_label || x_label;
    always @* begin
        if(p_digit || p_label) pixel_rgb=24'h24D883;
        else if(g_digit || g_label) pixel_rgb=24'hFACC15;
        else if(m_digit || m_label) pixel_rgb=24'hF97316;
        else if(x_digit || x_label) pixel_rgb=24'hF04444;
        else pixel_rgb=24'h102A50;
    end
    function letter_pixel;
        input [1:0] kind;
        input [9:0] x0;
        input [9:0] xpos,ypos;
        input den;
        reg [3:0] dx;
        reg [4:0] dy;
        begin
            dx=xpos-x0;
            dy=ypos-10'd8;
            letter_pixel=0;
            if(den && xpos>=x0 && xpos<x0+10'd13 &&
               ypos>=10'd8 && ypos<10'd27) begin
                case(kind)
                    2'd0: letter_pixel=(dx<2 ||
                        (dy<2 && dx<12) ||
                        (dy>=8 && dy<10 && dx<12) ||
                        (dx>=10 && dy<10)); // P
                    2'd1: letter_pixel=(dy<2 && dx>=2) ||
                        (dy>=17 && dx>=2) ||
                        (dx<2 && dy>=2 && dy<17) ||
                        (dx>=10 && dy>=10) ||
                        (dy>=9 && dy<11 && dx>=6); // G
                    2'd2: letter_pixel=dx<2 || dx>=11 ||
                        (dy<10 && (dx==(dy>>1)+2 ||
                                    dx==10-(dy>>1))); // M
                    default: letter_pixel=dx==(dy>>1)+1 ||
                        dx==11-(dy>>1); // X
                endcase
            end
        end
    endfunction
endmodule
