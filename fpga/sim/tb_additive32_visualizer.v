`timescale 1ns/1ps

module tb_additive32_visualizer;
    reg pixel_clk = 1'b0;
    always #20 pixel_clk = ~pixel_clk;

    reg rst_n = 1'b0;
    reg de = 1'b1;
    reg [9:0] pix_x = 10'd68;
    reg [9:0] pix_y = 10'd400;
    reg signed [15:0] audio_snapshot_async = 16'sd0;
    reg snapshot_toggle_async = 1'b0;
    reg timbre_snapshot_async = 1'b0;
    reg [1:0] program_snapshot_async = 2'd0;
    reg additive_active_snapshot_async = 1'b0;
    reg [7:0] additive_level_snapshot_async = 8'd0;
    reg [255:0] spectrum_bins_async = 256'd0;
    reg spectrum_toggle_async = 1'b0;
    wire [23:0] rgb;

    midi_visualizer dut (
        .pixel_clk(pixel_clk), .rst_n(rst_n), .de(de),
        .pix_x(pix_x), .pix_y(pix_y),
        .audio_snapshot_async(audio_snapshot_async),
        .snapshot_toggle_async(snapshot_toggle_async),
        .timbre_snapshot_async(timbre_snapshot_async),
        .program_snapshot_async(program_snapshot_async),
        .additive_active_snapshot_async(additive_active_snapshot_async),
        .additive_level_snapshot_async(additive_level_snapshot_async),
        .spectrum_bins_async(spectrum_bins_async),
        .spectrum_toggle_async(spectrum_toggle_async), .rgb(rgb)
    );

    task wait_pixel_domain;
        begin
            repeat (4) @(posedge pixel_clk);
            #1;
        end
    endtask

    initial begin
        wait_pixel_domain();
        rst_n = 1'b1;
        wait_pixel_domain();

        program_snapshot_async = 2'd2;
        timbre_snapshot_async = 1'b1;
        additive_active_snapshot_async = 1'b1;
        additive_level_snapshot_async = 8'd255;
        snapshot_toggle_async = 1'b1;
        wait_pixel_domain();

        if (rgb !== 24'hA78BFA) $fatal(1, "A H1 bar missing");
        pix_x = 10'd565; // harmonic 32, 64 + 31*16 + 5
        #1;
        if (rgb !== 24'hA78BFA) $fatal(1, "A H32 bar missing");
        pix_y = 10'd350;
        #1;
        if (rgb === 24'hA78BFA) $fatal(1, "H32 bar too tall");

        additive_level_snapshot_async = 8'd0;
        snapshot_toggle_async = 1'b0;
        wait_pixel_domain();
        pix_y = 10'd400;
        #1;
        if (rgb === 24'hA78BFA) $fatal(1, "zero-level A bar visible");

        program_snapshot_async = 2'd0;
        additive_active_snapshot_async = 1'b0;
        snapshot_toggle_async = 1'b1;
        spectrum_bins_async = {32{8'hff}};
        spectrum_toggle_async = 1'b1;
        wait_pixel_domain();
        if (rgb !== 24'h22D3EE) $fatal(1, "P FFT bar changed");

        program_snapshot_async = 2'd2;
        additive_active_snapshot_async = 1'b0;
        snapshot_toggle_async = 1'b0;
        wait_pixel_domain();
        if (rgb !== 24'h22D3EE) $fatal(1, "A fallback FFT bar missing");

        $display("PASS: A H1-H32, zero level, P FFT and A fallback FFT");
        $finish;
    end
endmodule
