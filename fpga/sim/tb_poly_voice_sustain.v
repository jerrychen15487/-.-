`timescale 1ns/1ps
module tb_poly_voice_sustain;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg frame_valid = 1'b0;
    reg [7:0] event_type = 8'd0;
    reg [7:0] data1 = 8'd0;
    reg [7:0] data2 = 8'd0;
    reg [3:0] voice_finished = 4'd0;
    wire [6:0] note0, note1, note2, note3;
    wire [6:0] velocity0, velocity1, velocity2, velocity3;
    wire [3:0] gate, retrigger;
    integer errors = 0;

    always #10 clk = ~clk;

    poly_voice_ctrl dut (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
        .event_type(event_type), .data1(data1), .data2(data2),
        .voice_finished(voice_finished),
        .note0(note0), .note1(note1), .note2(note2), .note3(note3),
        .velocity0(velocity0), .velocity1(velocity1),
        .velocity2(velocity2), .velocity3(velocity3),
        .gate(gate), .retrigger(retrigger)
    );

    task send_event;
        input [7:0] kind, param, value;
        begin
            @(negedge clk);
            event_type = kind; data1 = param; data2 = value;
            frame_valid = 1'b1;
            @(negedge clk);
            frame_valid = 1'b0;
            #1;
        end
    endtask

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                $display("ERROR: %0s", message);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #25 rst_n = 1'b1;
        send_event(8'h01, 8'd60, 8'd100);
        check(gate == 4'b0001 && dut.key_down == 4'b0001,
              "initial Note On");
        send_event(8'h03, 8'd64, 8'd96);
        check(dut.sustain_on, "CC64=96 pedal on");
        send_event(8'h02, 8'd60, 8'd0);
        check(gate == 4'b0001 && dut.key_down == 4'b0000,
              "pedal holds released key");
        send_event(8'h01, 8'd60, 8'd80);
        check(gate == 4'b0001 && dut.key_down == 4'b0001 && note0 == 7'd60,
              "repeated note reuses voice");
        send_event(8'h02, 8'd60, 8'd0);
        send_event(8'h01, 8'd64, 8'd90);
        check(gate == 4'b0011 && note0 == 7'd60 && note1 == 7'd64 &&
              dut.key_down == 4'b0010,
              "new note uses idle voice before pedal-held voice");
        send_event(8'h01, 8'd67, 8'd90);
        send_event(8'h02, 8'd67, 8'd0);
        check(gate == 4'b0111 && dut.key_down == 4'b0010,
              "one held and two pedal-held voices");
        send_event(8'h03, 8'd64, 8'd63);
        check(!dut.sustain_on && gate == 4'b0010,
              "CC64=63 releases only unpressed keys");
        send_event(8'h02, 8'd64, 8'd0);
        check(gate == 4'b0000, "normal Note Off after pedal up");
        send_event(8'h01, 8'd60, 8'd90);
        send_event(8'h01, 8'd64, 8'd90);
        send_event(8'h01, 8'd67, 8'd90);
        send_event(8'h01, 8'd72, 8'd90);
        send_event(8'h03, 8'd64, 8'd127);
        send_event(8'h02, 8'd60, 8'd0);
        check(gate == 4'b1111 && dut.key_down == 4'b1110,
              "pedal holds released voice when all four voices occupied");
        send_event(8'h01, 8'd74, 8'd90);
        check(gate == 4'b1111 && dut.key_down == 4'b1111 && note0 == 7'd74,
              "new note reuses pedal-held voice when no idle voice exists");
        send_event(8'h01, 8'd72, 8'd90);
        send_event(8'h03, 8'd123, 8'd0);
        check(gate == 4'b0000 && dut.key_down == 4'b0000,
              "CC123 clears voices");
        if (errors == 0) $display("PASS: CC64, repeated note, idle-first allocation, pedal-held reuse, release and CC123");
        else $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end
endmodule
