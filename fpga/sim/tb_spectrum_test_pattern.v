`timescale 1ns/1ps
module tb_spectrum_test_pattern;
    reg clk=0, rst_n=0, sample_tick=0;
    wire frame_valid;
    wire [7:0] event_type,data1,data2;
    integer index=0, cycles=0;
    reg [7:0] expected [0:7];
    always #10 clk=~clk;
    spectrum_test_pattern #(.REPEAT_SAMPLES(12)) dut (
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .frame_valid(frame_valid),.event_type(event_type),
        .data1(data1),.data2(data2)
    );
    initial begin
        expected[0]=55;expected[1]=62;expected[2]=69;expected[3]=76;
        expected[4]=55;expected[5]=62;expected[6]=69;expected[7]=76;
        repeat(3) @(negedge clk);
        rst_n=1;
        repeat(32) begin
            @(negedge clk);
            sample_tick=~sample_tick;
            #1;
            if(sample_tick) begin
                if(frame_valid) begin
                    if(index>=8 || event_type!=8'h01 ||
                       data1!=expected[index] || data2!=8'd100)
                        $fatal(1,"bad test event index=%0d note=%0d",index,data1);
                    index=index+1;
                end
                cycles=cycles+1;
            end
        end
        if(index!=8 || cycles!=16)
            $fatal(1,"wrong sequence length events=%0d ticks=%0d",index,cycles);
        $display("PASS spectrum test pattern: two 4-note bursts, no extra notes");
        $finish;
    end
endmodule
