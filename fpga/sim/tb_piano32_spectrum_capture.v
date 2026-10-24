`timescale 1ns/1ps
// Capture the actual HDL sample stream for a sustained MIDI 60 (C4).
// The synthesizer still processes all four voices inside each 1024-clock
// sample budget; only voice 0 has a nonzero envelope for this spectrum test.
module tb_piano32_spectrum_capture;
    reg clk=0, rst_n=0, sample_tick=0;
    reg [9:0] divider=0;
    reg [127:0] step_bus={4{32'd23012828}};
    reg [31:0] envelope_bus={24'd0,8'd255};
    reg [27:0] velocity_bus={21'd0,7'd127};
    reg [27:0] note_bus={4{7'd60}};
    wire signed [15:0] sample0,sample1,sample2,sample3;
    wire sample_valid,overrun;
    integer fd, captured=0, latency=0, max_latency=0;
    reg [1023:0] output_path;

    always #10 clk=~clk;
    always @(negedge clk) begin
        if(rst_n) begin
            sample_tick=(divider==0);
            divider=divider+1'b1;
        end
    end
    piano32_poly_synth dut (
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.enable(1'b1),
        .step_bus(step_bus),.retrigger_bus(4'd0),
        .envelope_bus(envelope_bus),.velocity_bus(velocity_bus),
        .note_bus(note_bus),.sample0(sample0),.sample1(sample1),
        .sample2(sample2),.sample3(sample3),
        .sample_valid(sample_valid),.overrun(overrun)
    );
    always @(posedge clk) if(rst_n) begin
        if(sample_tick) latency=0;
        else latency=latency+1;
        if(sample_valid) begin
            if(overrun || latency>=1024)
                $fatal(1,"32-partial sample deadline missed at %0d",captured);
            if(latency>max_latency) max_latency=latency;
            if(sample1!==0 || sample2!==0 || sample3!==0)
                $fatal(1,"silent voices produced output");
            $fdisplay(fd,"%0d",sample0);
            captured=captured+1;
            if(captured==4096) begin
                $fclose(fd);
                $display("PASS piano32 HDL capture: 4096 samples, max_latency=%0d/1024 cycles",max_latency);
                $finish;
            end
        end
    end
    initial begin
        if(!$value$plusargs("OUT=%s",output_path))
            $fatal(1,"pass +OUT=<writable sample file>");
        fd=$fopen(output_path,"w");
        if(fd==0) $fatal(1,"cannot open sample file");
        repeat(4) @(negedge clk);
        rst_n=1;
    end
    initial begin #100000000; $fatal(1,"capture timeout"); end
endmodule
