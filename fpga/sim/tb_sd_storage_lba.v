`timescale 1ns/1ps
module tb_sd_storage_lba;
    reg [1:0] region;
    reg directory_b;
    reg [2:0] slot;
    reg [12:0] index;
    reg [31:0] sector_count;
    wire [31:0] lba;
    wire valid;
    integer failures;

    sd_storage_lba dut (
        .region(region), .directory_b(directory_b), .slot(slot),
        .index(index), .sector_count(sector_count),
        .lba(lba), .valid(valid)
    );

    task expect;
        input [31:0] wanted_lba;
        input wanted_valid;
        begin
            #1;
            if (lba !== wanted_lba || valid !== wanted_valid) begin
                $display("FAIL region=%d b=%d slot=%d index=%d cap=%d got=%d/%b expected=%d/%b",
                         region, directory_b, slot, index, sector_count,
                         lba, valid, wanted_lba, wanted_valid);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        failures = 0;
        sector_count = 32'h03A3FC00;
        region = 0; directory_b = 0; slot = 0; index = 0;
        expect(32'd16384, 1'b1);
        index = 7; expect(32'd16391, 1'b1);
        index = 8; expect(32'd0, 1'b0);
        directory_b = 1; index = 0; expect(32'd16392, 1'b1);
        index = 7; expect(32'd16399, 1'b1);
        region = 1; slot = 0; index = 0; expect(32'd32768, 1'b1);
        slot = 5; index = 4095; expect(32'd77823, 1'b1);
        region = 2; slot = 0; index = 0; expect(32'd36864, 1'b1);
        slot = 5; index = 4095; expect(32'd81919, 1'b1);
        slot = 6; expect(32'd0, 1'b0);
        slot = 0; index = 4096; expect(32'd0, 1'b0);
        region = 3; index = 0; expect(32'd0, 1'b0);
        region = 2; slot = 5; index = 4095;
        sector_count = 32'd81919; expect(32'd0, 1'b0);
        sector_count = 32'd81920; expect(32'd81919, 1'b1);
        if (failures == 0) $display("PASS sd_storage_lba");
        else $fatal(1, "sd_storage_lba failures=%d", failures);
        $finish;
    end
endmodule
