// Keyboard and piano-roll renderer for the first 20 NOTE records read from
// the committed SD score. Geometry is cached before this pixel-domain view
// is enabled. It is a preview excerpt, not full-song practice/score playback.
module piano_blocks_demo (
    input  wire        de,
    input  wire [9:0]  pix_x,
    input  wire [9:0]  pix_y,
    input  wire [11:0] scroll_px_in,
    input  wire [127:0] note_on_mask,
    input  wire preview_loaded,
    input  wire preview_paused,
    input  wire [19:0] preview_valid_mask,
    input  wire [239:0] preview_start_px,preview_length_px,
    input  wire [199:0] preview_x_left,preview_x_right,
    input  wire [39:0] preview_part,
    output reg  [23:0] rgb
);
    // PSC2 NOTE records retain their native 960 PPQ timing. The score clock
    // is supplied by the caller, independent of video blanking/refresh.
    function integer score_start;
        input integer n;
        begin
            case (n)
                0: score_start=0;
                1: score_start=0;
                2: score_start=0;
                3: score_start=0;
                4: score_start=240;
                5: score_start=480;
                6: score_start=720;
                7: score_start=960;
                8: score_start=1200;
                9: score_start=1440;
                10: score_start=1680;
                11: score_start=1920;
                12: score_start=2160;
                13: score_start=2400;
                14: score_start=2640;
                15: score_start=2880;
                16: score_start=2880;
                17: score_start=2880;
                18: score_start=2880;
                19: score_start=3360;
                default: score_start=0;
            endcase
        end
    endfunction

    function integer score_length;
        input integer n;
        begin
            case (n)
                0: score_length=2880;
                1: score_length=2880;
                2: score_length=2880;
                3: score_length=240;
                4: score_length=240;
                5: score_length=240;
                6: score_length=240;
                7: score_length=240;
                8: score_length=240;
                9: score_length=240;
                10: score_length=240;
                11: score_length=240;
                12: score_length=240;
                13: score_length=240;
                14: score_length=240;
                15: score_length=960;
                16: score_length=960;
                17: score_length=960;
                18: score_length=480;
                19: score_length=480;
                default: score_length=1;
            endcase
        end
    endfunction

    function integer score_pitch;
        input integer n;
        begin
            case (n)
                0: score_pitch=53;
                1: score_pitch=57;
                2: score_pitch=60;
                3: score_pitch=81;
                4: score_pitch=79;
                5: score_pitch=77;
                6: score_pitch=76;
                7: score_pitch=77;
                8: score_pitch=76;
                9: score_pitch=74;
                10: score_pitch=72;
                11: score_pitch=74;
                12: score_pitch=72;
                13: score_pitch=70;
                14: score_pitch=69;
                15: score_pitch=53;
                16: score_pitch=55;
                17: score_pitch=62;
                18: score_pitch=72;
                19: score_pitch=70;
                default: score_pitch=60;
            endcase
        end
    endfunction

    function integer score_part;
        input integer n;
        begin
            case (n)
                0: score_part=1;
                1: score_part=1;
                2: score_part=1;
                3: score_part=2;
                4: score_part=2;
                5: score_part=2;
                6: score_part=2;
                7: score_part=2;
                8: score_part=2;
                9: score_part=2;
                10: score_part=2;
                11: score_part=2;
                12: score_part=2;
                13: score_part=2;
                14: score_part=2;
                15: score_part=1;
                16: score_part=1;
                17: score_part=1;
                18: score_part=2;
                19: score_part=2;
                default: score_part=1;
            endcase
        end
    endfunction

    // Full A0..C8 range: 52 white and 36 black keys, like ScorePreview.vue.
    function integer black_pitch;
        input integer pitch;
        begin
            case (pitch%12)
                1,3,6,8,10: black_pitch=1;
                default: black_pitch=0;
            endcase
        end
    endfunction
    function integer whites_before;
        input integer pitch;
        integer q;
        begin
            whites_before=0;
            for (q=21; q<pitch; q=q+1)
                if (!black_pitch(q)) whites_before=whites_before+1;
        end
    endfunction

    // Fixed 0.0502 pixel/tick preview scale; BPM changes tick progression,
    // not geometry. Q16 coefficient 3291 keeps full 88-key width.
    // The preview clock accumulates the 0.0502 px/tick scale once per music
    // tick; the 25 MHz renderer only compares the frame-stable pixel offset.
    wire [11:0] scroll_px = scroll_px_in;
    wire [19:0] bass_pixel, treble_pixel;
    genvar n;
    generate for (n=0; n<20; n=n+1) begin: excerpt
        wire [11:0] start_y=preview_start_px[n*12 +:12];
        wire [11:0] height=preview_length_px[n*12 +:12];
        wire [9:0] x_left=preview_x_left[n*10 +:10];
        wire [9:0] x_right=preview_x_right[n*10 +:10];
        wire [1:0] part=preview_part[n*2 +:2];
        wire signed [12:0] bottom_y =
            13'sd40 + $signed({1'b0,scroll_px}) -
            $signed({1'b0,start_y});
        wire signed [12:0] top_y = bottom_y - $signed({1'b0,height});
        wire visible = preview_loaded && preview_valid_mask[n] &&
            pix_x >= x_left && pix_x < x_right &&
            pix_y >= 10'd40 && pix_y < 10'd400 &&
            $signed({1'b0,pix_y}) >= top_y &&
            $signed({1'b0,pix_y}) < bottom_y;
        assign bass_pixel[n] = part[0] && visible;
        assign treble_pixel[n] = part[1] && visible;
    end endgenerate

    wire [87:0] black_pixel, black_pressed, white_pressed, white_border;
    genvar k;
    generate for (k=0; k<88; k=k+1) begin: keyboard
        localparam integer PITCH = k+21;
        localparam integer WHITE_INDEX = whites_before(PITCH);
        localparam integer WHITE_LEFT = WHITE_INDEX*640/52;
        localparam integer WHITE_RIGHT = (WHITE_INDEX+1)*640/52;
        if (black_pitch(PITCH)) begin: black_key
            localparam integer BLACK_LEFT = WHITE_LEFT-4;
            assign black_pixel[k] = pix_y >= 10'd401 && pix_y < 10'd450 &&
                                    pix_x >= BLACK_LEFT && pix_x < BLACK_LEFT+8;
            assign black_pressed[k] = black_pixel[k] && note_on_mask[PITCH];
            assign white_pressed[k] = 1'b0;
            assign white_border[k] = 1'b0;
        end else begin: white_key_area
            assign black_pixel[k] = 1'b0;
            assign black_pressed[k] = 1'b0;
            assign white_pressed[k] = pix_y >= 10'd401 && pix_y < 10'd480 &&
                pix_x >= WHITE_LEFT && pix_x < WHITE_RIGHT && note_on_mask[PITCH];
            assign white_border[k] = pix_x == WHITE_LEFT;
        end
    end endgenerate

    always @(*) begin
        if (!de)                   rgb = 24'h000000;
        else if(preview_paused && pix_y>=10'd10 && pix_y<10'd28 &&
                ((pix_x>=10'd593 && pix_x<10'd598) ||
                 (pix_x>=10'd603 && pix_x<10'd608)))
                                    rgb = 24'hFFFFFF;
        else if (|treble_pixel)    rgb = 24'h218A7D;
        else if (|bass_pixel)      rgb = 24'hE9A255;
        else if (pix_y == 10'd400) rgb = 24'h18E080;
        else if (pix_y < 10'd40)   rgb = 24'h102A50;
        else if (pix_y > 10'd400) begin
            if (|black_pressed)    rgb = 24'h31B6F5;
            else if (|black_pixel)  rgb = 24'h182030;
            else if (|white_pressed) rgb = 24'h79D7FF;
            else if (|white_border) rgb = 24'h8295A7;
            else                    rgb = 24'hDFE8F4;
        end else                    rgb = 24'h111A2B;
    end
endmodule
