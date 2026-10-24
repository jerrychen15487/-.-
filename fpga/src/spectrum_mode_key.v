// NEO Dock KEY2: short release switches the four-tone test; long release
// toggles the optional echo effect. Neither gesture resets the SD score store.
module spectrum_mode_key #(
    parameter integer DEBOUNCE_CYCLES = 500000,
    parameter integer LONG_PRESS_UNITS = 100
) (
    input wire clk,
    input wire rst_n,
    input wire key_n,
    output reg test_mode,
    output reg echo_enabled
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] key_sync;
    reg key_stable;
    reg [18:0] debounce_count;
    reg [6:0] press_units;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync <= 2'b11;
            key_stable <= 1'b1;
            debounce_count <= 19'd0;
            press_units <= 7'd0;
            test_mode <= 1'b0;
            echo_enabled <= 1'b0;
        end else begin
            key_sync <= {key_sync[0], key_n};
            if (key_sync[1] != key_stable) begin
                if (debounce_count == DEBOUNCE_CYCLES-1) begin
                    key_stable <= key_sync[1];
                    debounce_count <= 19'd0;
                    if (!key_sync[1])
                        press_units <= 7'd0;
                    else if (press_units >= LONG_PRESS_UNITS)
                        echo_enabled <= ~echo_enabled;
                    else
                        test_mode <= ~test_mode;
                end else
                    debounce_count <= debounce_count + 1'b1;
            end else if (!key_stable) begin
                if (debounce_count == DEBOUNCE_CYCLES-1) begin
                    debounce_count <= 19'd0;
                    if (press_units != 7'd127)
                        press_units <= press_units + 1'b1;
                end else
                    debounce_count <= debounce_count + 1'b1;
            end else
                debounce_count <= 19'd0;
        end
    end
endmodule
