`timescale 1ns/1ps
module tb_psc2_note_stream;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, byte_valid=0;
    reg [31:0] byte_offset=0;
    reg [7:0] byte_data=0;
    wire note_valid,descriptor_valid;
    wire [31:0] note_index,start_tick,duration_tick,total_notes;
    wire [6:0] pitch;
    wire [1:0] part_mask;
    wire score_onset;
    psc2_note_stream dut(
        .clk(clk),.rst_n(rst_n),.byte_valid(byte_valid),
        .byte_offset(byte_offset),.byte_data(byte_data),
        .note_valid(note_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .pitch(pitch),.part_mask(part_mask),
        .score_onset(score_onset),
        .descriptor_valid(descriptor_valid),.total_notes(total_notes)
    );
    integer offset,seen;
    function [7:0] fixture_byte;
        input integer n;
        begin
            fixture_byte=0;
            case(n)
                36:fixture_byte=1;
                64:fixture_byte=2;
                72:fixture_byte=128;
                80:fixture_byte=2;
                84:fixture_byte=16;
                132:fixture_byte=8'hE0;
                133:fixture_byte=1;
                136:fixture_byte=60;
                138:fixture_byte=2;
                139:fixture_byte=1;
                144:fixture_byte=240;
                148:fixture_byte=240;
                152:fixture_byte=64;
                154:fixture_byte=2;
                default:fixture_byte=0;
            endcase
        end
    endfunction
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        seen=0;
        for(offset=0;offset<160;offset=offset+1) begin
            byte_valid=1; byte_offset=offset; byte_data=fixture_byte(offset);
            @(negedge clk);
            if(note_valid) begin
                if(note_index!==seen) $fatal(1,"note index %0d expected %0d",note_index,seen);
                if(seen==0 && (pitch!==60 || start_tick!==0 ||
                    duration_tick!==480 || part_mask!==2 ||
                    score_onset!==1))
                    $fatal(1,"first NOTE wrong");
                if(seen==1 && (pitch!==64 || start_tick!==240 ||
                    duration_tick!==240 || part_mask!==2 ||
                    score_onset!==0))
                    $fatal(1,"second NOTE wrong");
                seen=seen+1;
            end
        end
        byte_valid=0;
        if(!descriptor_valid || total_notes!==2 || seen!==2)
            $fatal(1,"descriptor=%b count=%0d seen=%0d",descriptor_valid,total_notes,seen);
        $display("PASS psc2_note_stream: %0d NOTE records",seen);
        $finish;
    end
endmodule
