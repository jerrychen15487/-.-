`timescale 1ns/1ps
module tb_poly32_partial_scheduler;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg sample_tick = 0;
    wire job_valid, frame_done, overrun;
    wire [4:0] voice0, voice1;
    wire [5:0] partial;
    integer ticks = 0;
    integer jobs = 0;
    reg [31:0] seen [0:31];
    integer i;
    poly32_partial_scheduler dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .job_valid(job_valid), .voice0(voice0), .voice1(voice1),
        .partial(partial), .frame_done(frame_done), .overrun(overrun)
    );
    initial begin
        for (i=0; i<32; i=i+1) seen[i]=0;
        repeat (3) @(negedge clk);
        rst_n=1;
        @(negedge clk); sample_tick=1;
        @(negedge clk); sample_tick=0;
        while (!frame_done && ticks < 1024) begin
            @(negedge clk);
            ticks=ticks+1;
            if (job_valid) begin
                if (voice0 > 15 || voice1 < 16 || voice1 > 31 ||
                    partial < 1 || partial > 32)
                    $fatal(1, "bad job address");
                if (seen[voice0][partial-1] || seen[voice1][partial-1])
                    $fatal(1, "duplicate job");
                seen[voice0][partial-1]=1;
                seen[voice1][partial-1]=1;
                jobs=jobs+2;
            end
        end
        if (!frame_done || jobs != 1024 || overrun)
            $fatal(1, "scheduler failed: done=%b jobs=%d overrun=%b", frame_done, jobs, overrun);
        for (i=0; i<32; i=i+1)
            if (seen[i] !== 32'hffffffff)
                $fatal(1, "voice %0d missing partials: %h", i, seen[i]);
        $display("PASS: 32 voices x 32 partials, 2 jobs/clock, %0d clocks including drain", ticks);
        $finish;
    end
endmodule
