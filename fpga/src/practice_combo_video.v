`timescale 1ns/1ps
// Two small seven-segment digits at the top of the piano-roll preview.
// The caller overlays only lit pixels, preserving the existing background.
module practice_combo_video #(
    parameter [9:0] X0=10'd70
) (
    input wire de,
    input wire [9:0] x, y,
    input wire [6:0] combo,
    output wire pixel_on
);
    wire [3:0] tens = combo>=7'd90 ? 4'd9 :
        combo>=7'd80 ? 4'd8 :
        combo>=7'd70 ? 4'd7 :
        combo>=7'd60 ? 4'd6 :
        combo>=7'd50 ? 4'd5 :
        combo>=7'd40 ? 4'd4 :
        combo>=7'd30 ? 4'd3 :
        combo>=7'd20 ? 4'd2 :
        combo>=7'd10 ? 4'd1 : 4'd0;
    wire [6:0] tens_value = {3'd0,tens};
    wire [6:0] ones = combo - (tens_value*7'd10);
    wire first_digit = x>=X0 && x<X0+10'd12;
    wire second_digit = x>=X0+10'd18 && x<X0+10'd30;
    wire [3:0] dx = first_digit ? x-X0 : x-(X0+10'd18);
    wire [4:0] dy = y-10'd8;
    wire [6:0] segments = glyph(first_digit ? tens_value[3:0] : ones[3:0]);
    wire a = segments[6] && dy<2 && dx>=2 && dx<10;
    wire b = segments[5] && dx>=10 && dy>=2 && dy<9;
    wire c = segments[4] && dx>=10 && dy>=10 && dy<17;
    wire d = segments[3] && dy>=17 && dy<19 && dx>=2 && dx<10;
    wire e = segments[2] && dx<2 && dy>=10 && dy<17;
    wire f = segments[1] && dx<2 && dy>=2 && dy<9;
    wire g = segments[0] && dy>=9 && dy<11 && dx>=2 && dx<10;
    assign pixel_on = de && (first_digit || second_digit) &&
        y>=10'd8 && y<10'd27 && (a||b||c||d||e||f||g);

    function [6:0] glyph;
        input [3:0] digit;
        begin
            case(digit)
                4'd0:glyph=7'b1111110;
                4'd1:glyph=7'b0110000;
                4'd2:glyph=7'b1101101;
                4'd3:glyph=7'b1111001;
                4'd4:glyph=7'b0110011;
                4'd5:glyph=7'b1011011;
                4'd6:glyph=7'b1011111;
                4'd7:glyph=7'b1110000;
                4'd8:glyph=7'b1111111;
                4'd9:glyph=7'b1111011;
                default:glyph=7'b0000000;
            endcase
        end
    endfunction
endmodule
