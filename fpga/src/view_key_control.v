// KEY1 interaction on the 50 MHz system clock:
// short press enters the piano roll, then pauses/resumes it;
// long press in the piano roll returns to waveform; long press in waveform
// enters the stored score page. There, single/double/long presses switch
// notation, advance one page, and exit respectively.
module view_key_control #(
    parameter integer DEBOUNCE_CYCLES = 500000,
    parameter integer LONG_PRESS_UNITS = 100,
    parameter integer DOUBLE_CLICK_CYCLES = 12500000
) (
    input wire clk,rst_n,key_n,
    input wire page_done,page_available,
    input wire [5:0] page_selected_index,
    input wire [15:0] page_completed_token,
    output reg piano_demo_mode,
    output reg preview_paused,
    output reg preview_request,
    output reg sheet_mode,page_request,
    output reg [1:0] page_notation,
    output reg [5:0] page_index,
    output reg [15:0] page_request_token
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] key_sync;
    reg key_stable;
    reg [18:0] key_count;
    reg [6:0] press_units;
    reg click_pending;
    reg [23:0] click_count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            key_sync<=2'b11;
            key_stable<=1'b1;
            key_count<=0;
            press_units<=0;
            piano_demo_mode<=0;
            preview_paused<=0;
            preview_request<=0;
            sheet_mode<=0;page_request<=0;page_notation<=2'd1;
            page_index<=0;page_request_token<=0;
            click_pending<=0;click_count<=0;
        end else begin
            preview_request<=0;
            page_request<=0;
            // A newer key request wins over an older SD read completion.
            if(page_done && page_available &&
               page_completed_token==page_request_token)
                page_index<=page_selected_index;
            key_sync<={key_sync[0],key_n};
            if(key_sync[1]!=key_stable) begin
                if(key_count==DEBOUNCE_CYCLES-1) begin
                    key_stable<=key_sync[1];
                    key_count<=0;
                    if(!key_sync[1]) begin
                        press_units<=0;
                    end else if(sheet_mode) begin
                        if(press_units>=LONG_PRESS_UNITS) begin
                            sheet_mode<=0;click_pending<=0;
                        end else if(click_pending) begin
                            click_pending<=0;
                            page_index<=page_index+1'b1;
                            page_request<=1;
                            page_request_token<=page_request_token+1'b1;
                        end else begin
                            click_pending<=1;click_count<=0;
                        end
                    end else if(!piano_demo_mode) begin
                        if(press_units>=LONG_PRESS_UNITS) begin
                            sheet_mode<=1;
                            page_notation<=2'd1;
                            page_index<=0;click_pending<=0;
                            page_request<=1;
                            page_request_token<=page_request_token+1'b1;
                        end else begin
                            piano_demo_mode<=1;
                            preview_paused<=0;
                            preview_request<=1;
                        end
                    end else if(press_units>=LONG_PRESS_UNITS) begin
                        piano_demo_mode<=0;
                        preview_paused<=0;
                    end else begin
                        preview_paused<=~preview_paused;
                    end
                end else key_count<=key_count+1'b1;
            end else if(!key_stable) begin
                if(key_count==DEBOUNCE_CYCLES-1) begin
                    key_count<=0;
                    if(press_units!=7'd127)
                        press_units<=press_units+1'b1;
                end else key_count<=key_count+1'b1;
            end else key_count<=0;
            if(sheet_mode && click_pending && key_stable &&
               key_sync[1]==key_stable) begin
                if(click_count==DOUBLE_CLICK_CYCLES-1) begin
                    click_pending<=0;
                    page_notation<=page_notation==2'd1 ? 2'd2 : 2'd1;
                    page_request<=1;
                    page_request_token<=page_request_token+1'b1;
                end else click_count<=click_count+1'b1;
            end
        end
    end
endmodule
