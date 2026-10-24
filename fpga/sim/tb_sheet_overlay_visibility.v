`timescale 1ns/1ps
module tb_sheet_overlay_visibility;
    reg sys_clk=0,pixel_clk=0,rst_n=0;
    reg [3:0] stage=0;
    reg ready=0;
    reg [9:0] x=0,y=0;
    integer s;
    always #10 sys_clk=~sys_clk;
    always #20 pixel_clk=~pixel_clk;

    top dut(.sys_clk(sys_clk),.sys_rst_n(rst_n));
    initial begin
        force dut.pixel_clk=pixel_clk;
        force dut.video_rst_n=rst_n;
        force dut.video_de=1'b1;
        force dut.video_x=x;
        force dut.video_y=y;
        force dut.page_stage_video_sync=stage;
        force dut.page_ready_video=ready;
        force dut.sheet_mode_video_sync=2'b11;
        force dut.spectrum_mode_video_sync=2'b00;
        force dut.sheet_rgb=24'h123456;

        repeat(2) @(negedge pixel_clk);
        rst_n=1;
        // Normal transitions 0->1->2->7 must not flash debug colors.
        for(s=0;s<4;s=s+1) begin
            stage=(s==3) ? 4'd7 : s;
            ready=(s==3);y=0;
            repeat(2) @(negedge pixel_clk);
            if(dut.page_status_bar_q!==1'b0)
                $fatal(1,"normal stage %0d flashes status bar",stage);
            if(dut.video_rgb_raw!==24'h123456)
                $fatal(1,"normal stage %0d replaces sheet pixels",stage);
            y=40;
            repeat(2) @(negedge pixel_clk);
            if(dut.diag_grid_area_q!==1'b0)
                $fatal(1,"normal stage %0d flashes diagnostic grid",stage);
            if(dut.video_rgb_raw!==24'h123456)
                $fatal(1,"normal stage %0d overlays sheet body",stage);
        end

        stage=4'd4;ready=0;y=0;
        repeat(2) @(negedge pixel_clk);
        if(dut.page_status_bar_q!==1'b1)
            $fatal(1,"failure status bar hidden");
        y=40;
        repeat(2) @(negedge pixel_clk);
        if(dut.diag_grid_area_q!==1'b1)
            $fatal(1,"failure diagnostic version hidden");
        $display("PASS sheet overlay: transitions clean, errors visible");
        $finish;
    end
endmodule
