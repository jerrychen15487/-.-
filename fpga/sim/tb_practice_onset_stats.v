`timescale 1ns/1ps
module tb_practice_onset_stats;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,clear=0,restart=0,hit_valid=0,miss_valid=0;
    reg [2:0] hit_kind=0;
    wire [6:0] combo,max_combo,perfect_count,good_count,miss_count,wrong_count;
    integer errors=0;
    practice_onset_stats dut(
        .clk(clk),.rst_n(rst_n),.clear(clear),.restart(restart),
        .hit_valid(hit_valid),.hit_kind(hit_kind),.miss_valid(miss_valid),
        .combo(combo),.max_combo(max_combo),
        .perfect_count(perfect_count),.good_count(good_count),
        .miss_count(miss_count),.wrong_count(wrong_count));
    task step;
        input [2:0] kind;
        input miss;
        begin
            @(negedge clk);hit_valid=!miss;hit_kind=kind;miss_valid=miss;
            @(negedge clk);hit_valid=0;miss_valid=0;
        end
    endtask
    task check;
        input [6:0] c,m,p,g,mi,w;
        begin
            #1;
            if({combo,max_combo,perfect_count,good_count,miss_count,wrong_count}
               !=={c,m,p,g,mi,w}) begin
                $display("FAIL got combo/max/P/G/M/W=%0d/%0d/%0d/%0d/%0d/%0d",
                    combo,max_combo,perfect_count,good_count,miss_count,wrong_count);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(2) @(negedge clk);rst_n=1;
        step(3,0);step(2,0);check(2,2,1,1,0,0);
        step(1,0);step(4,0);check(2,2,1,1,0,0);
        step(0,1);check(0,2,1,1,1,0);
        step(3,0);step(0,0);check(0,2,2,1,1,1);
        step(2,0);check(1,2,2,2,1,1);
        @(negedge clk);restart=1;
        @(negedge clk);restart=0;check(0,0,0,0,0,0);
        step(3,0);check(1,1,1,0,0,0);
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;check(0,0,0,0,0,0);
        if(errors!=0) $fatal(1,"onset stats errors=%0d",errors);
        $display("PASS practice_onset_stats");
        $finish;
    end
endmodule
