module midi_note_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_valid,
    input  wire [7:0] event_type,
    input  wire [7:0] data1,
    input  wire [7:0] data2,
    output reg  [6:0] note,
    output reg  [6:0] velocity,
    output reg        gate,
    output reg        retrigger
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note      <= 7'd60;
            velocity  <= 7'd0;
            gate      <= 1'b0;
            retrigger <= 1'b0;
        end else begin
            retrigger <= 1'b0;
            if (frame_valid) begin
                if ((event_type == 8'h01) && (data2[6:0] != 0)) begin
                    note      <= data1[6:0];
                    velocity  <= data2[6:0];
                    gate      <= 1'b1;
                    retrigger <= 1'b1;
                end else if (((event_type == 8'h02) ||
                              ((event_type == 8'h01) && (data2[6:0] == 0))) &&
                             (data1[6:0] == note)) begin
                    gate <= 1'b0;
                end else if ((event_type == 8'h03) && (data1 == 8'd123)) begin
                    gate <= 1'b0;
                end
            end
        end
    end
endmodule
