`timescale 1ns/1ps
module tb_practice_stats_video;
    reg de=1;
    reg [9:0] x=0,y=0;
    reg [6:0] perfect_count=0,good_count=0,miss_count=0,wrong_count=0;
    wire pixel_on;
    wire [23:0] pixel_rgb;
    integer errors=0;
    practice_stats_video dut(.*);
    task check;
        input [9:0] xpos,ypos;
        input expected_on;
        input [23:0] expected_rgb;
        begin
            x=xpos;y=ypos;#1;
            if(pixel_on!==expected_on ||
               (expected_on && pixel_rgb!==expected_rgb)) begin
                $display("FAIL x=%0d y=%0d on=%b rgb=%h",xpos,ypos,pixel_on,pixel_rgb);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        perfect_count=7'd42;
        good_count=7'd21;
        miss_count=7'd19;
        wrong_count=7'd9;
        check(10'd118,10'd8,1'b1,24'h24D883); // P label
        check(10'd138,10'd8,1'b0,0); // 4 has no top segment
        check(10'd213,10'd8,1'b1,24'hFACC15); // Good tens=2
        check(10'd231,10'd8,1'b0,0); // Good ones=1
        check(10'd288,10'd8,1'b0,0); // Miss tens=1
        check(10'd363,10'd8,1'b1,24'hF04444); // Wrong tens=0
        de=0;check(10'd118,10'd8,1'b0,0);
        if(errors!=0) $fatal(1,"stats video errors=%0d",errors);
        $display("PASS practice_stats_video");
        $finish;
    end
endmodule
