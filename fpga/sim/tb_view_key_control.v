`timescale 1ns/1ps
module tb_view_key_control;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,key_n=1;
    wire piano_demo_mode,preview_paused,preview_request;
    wire sheet_mode,page_request;
    wire [1:0] page_notation;
    wire [5:0] page_index;
    reg page_done=0,page_available=0;
    reg [5:0] page_selected_index=0;
    reg [15:0] page_completed_token=0;
    wire [15:0] page_request_token;
    reg saw_request=0,saw_page_request=0;
    view_key_control #(.DEBOUNCE_CYCLES(4),.LONG_PRESS_UNITS(5),
        .DOUBLE_CLICK_CYCLES(25)) dut (
        .clk(clk),.rst_n(rst_n),.key_n(key_n),
        .page_done(page_done),.page_available(page_available),
        .page_selected_index(page_selected_index),
        .page_completed_token(page_completed_token),
        .piano_demo_mode(piano_demo_mode),
        .preview_paused(preview_paused),
        .preview_request(preview_request),
        .sheet_mode(sheet_mode),.page_request(page_request),
        .page_notation(page_notation),.page_index(page_index),
        .page_request_token(page_request_token)
    );
    always @(posedge clk) if(preview_request) saw_request<=1;
    always @(posedge clk) if(page_request) saw_page_request<=1;
    task press_key;
        input integer hold_cycles;
        begin
            @(negedge clk);key_n=0;
            repeat(hold_cycles) @(negedge clk);
            key_n=1;
            repeat(7) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        press_key(12);
        if(!piano_demo_mode || preview_paused || !saw_request)
            $fatal(1,"short press must enter preview and load SD notes");
        saw_request=0;
        press_key(12);
        if(!piano_demo_mode || !preview_paused || saw_request)
            $fatal(1,"short press must pause without reloading notes");
        press_key(12);
        if(!piano_demo_mode || preview_paused)
            $fatal(1,"short press must resume");
        press_key(32);
        if(piano_demo_mode || preview_paused)
            $fatal(1,"long press must return to waveform view");
        press_key(32);
        if(!sheet_mode || page_notation!=1 || !saw_page_request)
            $fatal(1,"long press in waveform must load staff page");
        saw_page_request=0;
        press_key(12);
        repeat(30) @(negedge clk);
        if(!sheet_mode || page_notation!=2 || !saw_page_request)
            $fatal(1,"short press in page must load jianpu page");
        saw_page_request=0;
        press_key(12);
        press_key(12);
        if(page_notation!=2 || page_index!=1 || !saw_page_request)
            $fatal(1,"double press must advance without switching notation");
        @(negedge clk);page_done=1;page_available=1;
        page_selected_index=0;
        page_completed_token=page_request_token-1'b1;
        @(negedge clk);page_done=0;page_available=0;
        if(page_index!=1)
            $fatal(1,"stale page completion changed pending index");
        @(negedge clk);page_done=1;page_available=1;
        page_completed_token=page_request_token;
        @(negedge clk);page_done=0;page_available=0;
        if(page_index!=0) $fatal(1,"wrapped page index not accepted");
        press_key(32);
        if(sheet_mode)
            $fatal(1,"long press in page must return to waveform");
        $display("PASS KEY1 preview/pause, staff/jianpu/next-page/exit");
        $finish;
    end
endmodule
