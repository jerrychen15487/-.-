`timescale 1ns/1ps

module tb_pcm5102_i2s_tx;
    reg clk = 0;
    reg rst_n = 0;
    reg signed [15:0] sample_left = 16'hA55A;
    reg signed [15:0] sample_right = 16'h3CC3;
    wire bck, ws, din;
    integer bit_pos = -2;
    integer frames = 0;
    integer edges = 0;
    integer previous_rise = 0;
    integer previous_left = 0;
    reg previous_ws = 1'b1;
    reg [15:0] expected;

    always #10 clk = ~clk;

    pcm5102_i2s_tx dut (
        .clk(clk), .rst_n(rst_n),
        .sample_left(sample_left), .sample_right(sample_right),
        .bck(bck), .ws(ws), .din(din)
    );

    // The DAC samples on BCK rising edges. After each WS transition the
    // first edge is the I2S delay bit; the following 16 carry MSB first.
    always @(posedge bck) if (rst_n) begin
        #1;
        if (previous_rise != 0 && $time - previous_rise != 320)
            $fatal(1, "BCK period %0t ns, expected 320 ns", $time - previous_rise);
        previous_rise = $time;
        edges = edges + 1;
        if (ws != previous_ws) begin
            bit_pos = -1;
            previous_ws = ws;
            if (!ws) begin
                if (previous_left != 0 && $time - previous_left != 20480)
                    $fatal(1, "LRCK period %0t ns, expected 20480 ns", $time - previous_left);
                previous_left = $time;
                frames = frames + 1;
            end
        end else begin
            bit_pos = bit_pos + 1;
        end
        if (bit_pos == -1 || bit_pos >= 16) begin
            if (din !== 1'b0)
                $fatal(1, "padding/delay bit nonzero: ws=%b pos=%0d", ws, bit_pos);
        end else if (bit_pos >= 0) begin
            expected = ws ? 16'h3CC3 : 16'hA55A;
            if (din !== expected[15-bit_pos])
                $fatal(1, "I2S bit wrong: ws=%b pos=%0d din=%b expected=%b",
                       ws, bit_pos, din, expected[15-bit_pos]);
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        wait (frames == 4);
        if (edges < 190) $fatal(1, "too few BCK edges: %0d", edges);
        $display("PASS: 4 I2S frames, 16-bit stereo samples, 32-bit slots, 48.828125 kHz");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "timeout");
    end
endmodule
