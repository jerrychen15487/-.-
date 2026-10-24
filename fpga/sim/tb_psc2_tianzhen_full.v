`timescale 1ns/1ps
module tb_psc2_tianzhen_full;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,byte_valid=0;
    reg [31:0] byte_offset=0;
    reg [7:0] byte_data=0;
    wire note_valid,descriptor_valid,score_onset;
    wire [31:0] note_index,start_tick,duration_tick,total_notes;
    wire [6:0] pitch;
    wire [1:0] part_mask;
    wire [15:0] default_bpm;
    psc2_note_stream dut(
        .clk(clk),.rst_n(rst_n),.byte_valid(byte_valid),
        .byte_offset(byte_offset),.byte_data(byte_data),
        .note_valid(note_valid),.note_index(note_index),
        .start_tick(start_tick),.duration_tick(duration_tick),
        .pitch(pitch),.part_mask(part_mask),.score_onset(score_onset),
        .descriptor_valid(descriptor_valid),.total_notes(total_notes),
        .default_bpm(default_bpm)
    );

    integer fd,n,c,seen=0;
    reg [31:0] prior_start=0;
    always @(posedge clk) begin
        if(rst_n && note_valid) begin
            if(note_index!==seen)
                $fatal(1,"NOTE index %0d expected %0d",note_index,seen);
            if(duration_tick==0 || pitch<21 || pitch>108 || part_mask==0)
                $fatal(1,"invalid NOTE %0d: tick=%0d duration=%0d pitch=%0d part=%0d",
                    note_index,start_tick,duration_tick,pitch,part_mask);
            if(seen!=0 && start_tick<prior_start)
                $fatal(1,"NOTE order regressed at %0d",note_index);
            prior_start=start_tick;
            seen=seen+1;
        end
    end

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        fd=$fopen("sim/tianzhen-fixture.pseq","rb");
        if(fd==0) $fatal(1,"missing real Tianzhen PSC2 fixture");
        n=0;
        c=$fgetc(fd);
        while(c>=0) begin
            byte_valid=1;
            byte_offset=n;
            byte_data=c[7:0];
            n=n+1;
            @(negedge clk);
            c=$fgetc(fd);
        end
        byte_valid=0;
        $fclose(fd);
        repeat(2) @(negedge clk);
        if(n!=759412 || !descriptor_valid || total_notes!=414 ||
           default_bpm!=112 || seen!=414)
            $fatal(1,"full sample mismatch: bytes=%0d descriptor=%b total=%0d bpm=%0d seen=%0d",
                n,descriptor_valid,total_notes,default_bpm,seen);
        $display("PASS Tianzhen PSC2 full NOTE stream: %0d bytes, %0d/%0d notes, BPM=%0d",
            n,seen,total_notes,default_bpm);
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule
