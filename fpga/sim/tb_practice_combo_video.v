`timescale 1ns/1ps
module tb_practice_combo_video;
    reg [9:0] x=0,y=0;
    reg [6:0] combo=0;
    reg de=1;
    wire pixel_on;
    integer errors=0;
    practice_combo_video dut(.de(de),.x(x),.y(y),.combo(combo),.pixel_on(pixel_on));
    task check;
        input [6:0] value;
        input [9:0] xpos,ypos;
        input expected;
        begin
            combo=value;x=xpos;y=ypos;#1;
            if(pixel_on!==expected) begin
                $display("FAIL combo=%0d x=%0d y=%0d got=%b expected=%b",value,xpos,ypos,pixel_on,expected);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        // At x=73,y=8 the first digit's top segment is lit for 4, not 0/1.
        check(7'd42,10'd73,10'd8,1'b0);
        check(7'd42,10'd90,10'd8,1'b1);
        check(7'd99,10'd73,10'd8,1'b1);
        check(7'd99,10'd91,10'd8,1'b1);
        check(7'd42,10'd73,10'd27,1'b0);
        if(errors!=0) $fatal(1,"combo video errors=%0d",errors);
        $display("PASS practice_combo_video");
        $finish;
    end
endmodule
