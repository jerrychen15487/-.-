`timescale 1ns/1ps
module tb_sd_score_note_read;
    parameter integer MAX_NOTES=20;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0,block_done=0;
    wire block_start,block_write,block_guard_valid;
    wire [31:0] block_lba;
    wire [8:0] buffer_addr;
    wire done,io_failed,invalid_spec,note_valid,descriptor_valid;
    wire [31:0] note_index,start_tick,duration_tick,total_notes;
    wire [6:0] pitch;
    wire [1:0] part_mask;
    wire [2:0] dynamic;
    wire score_onset,score_hold,score_velocity;
    wire [31:0] file_pos=((block_lba-32'd32768)<<9)+buffer_addr;
    wire [7:0] buffer_rdata=fixture_byte(file_pos);
    sd_score_note_read #(.MAX_NOTES(MAX_NOTES)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.slot(3'd0),
        .total_bytes(32'd1536),.sector_count(32'd100000),
        .block_ready(1'b1),.block_done(block_done),
        .block_error(8'd0),.buffer_rdata(buffer_rdata),
        .block_start(block_start),.block_write(block_write),
        .block_lba(block_lba),.block_guard_valid(block_guard_valid),
        .buffer_addr(buffer_addr),.done(done),.io_failed(io_failed),
        .invalid_spec(invalid_spec),.note_valid(note_valid),
        .descriptor_valid(descriptor_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .total_notes(total_notes),.pitch(pitch),.part_mask(part_mask),
        .dynamic(dynamic),.score_onset(score_onset),
        .score_hold(score_hold),.score_velocity(score_velocity)
    );
    function [7:0] fixture_byte;
        input [31:0] n;
        begin
            fixture_byte=0;
            case(n)
                36:fixture_byte=1;
                64:fixture_byte=2;
                72:fixture_byte=8'hF0; // 496
                73:fixture_byte=1;
                80:fixture_byte=2;
                84:fixture_byte=16;
                500:fixture_byte=8'hE0;
                501:fixture_byte=1;
                504:fixture_byte=60;
                505:fixture_byte=4;
                506:fixture_byte=2;
                507:fixture_byte=7;
                512:fixture_byte=240;
                516:fixture_byte=240;
                520:fixture_byte=64;
                522:fixture_byte=2;
                default:fixture_byte=0;
            endcase
        end
    endfunction
    integer reads=0,notes=0,cycles=0;
    always @(posedge clk) begin
        if(!rst_n) block_done<=0;
        else begin
            block_done<=block_start;
            if(block_start) begin
                if(block_write || !block_guard_valid ||
                   block_lba!==32'd32768+reads)
                    $fatal(1,"incorrect SD read request");
                reads=reads+1;
            end
            if(note_valid) begin
                if(note_index!==notes ||
                   (notes==0 && (pitch!==60 || duration_tick!==480 ||
                     dynamic!==4 || !score_onset || !score_hold ||
                     !score_velocity)) ||
                   (notes==1 && (pitch!==64 || start_tick!==240)))
                    $fatal(1,"incorrect decoded note %0d",notes);
                notes=notes+1;
            end
            cycles=cycles+1;
            if(cycles>700) $fatal(1,"timeout");
            if(done) begin
                if(io_failed || invalid_spec || reads!=2 ||
                   notes!=(MAX_NOTES<2 ? MAX_NOTES : 2) ||
                   !descriptor_valid || total_notes!=2)
                    $fatal(1,"read failed reads=%0d notes=%0d",reads,notes);
                $display("PASS sd_score_note_read: 2 sectors, 2 notes, no writes");
                $finish;
            end
        end
    end
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;start=1;
        @(negedge clk);
        start=0;
    end
endmodule
