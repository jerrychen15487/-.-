// Address decoder for the dedicated score card. No SD pins or write command
// are driven here. All score-store requests must pass this guard before they
// reach a future block device; the V3 diagnostic LBA 8192 is never emitted.
module sd_storage_lba (
    input  wire [1:0]  region,       // 0=directory, 1=data, 2=progress log
    input  wire        directory_b,  // 0=A, 1=B; ignored for other regions
    input  wire [2:0]  slot,         // 0..5; ignored for directory
    input  wire [12:0] index,        // 0..7 directory; 0..4095 slot regions
    input  wire [31:0] sector_count, // exclusive card capacity from CSD
    output reg  [31:0] lba,
    output reg         valid
);
    localparam [31:0] DIRECTORY_A = 32'd16384;
    localparam [31:0] DIRECTORY_B = 32'd16392;
    localparam [31:0] SLOT_BASE   = 32'd32768;
    localparam [31:0] SLOT_SIZE   = 32'd8192;
    localparam [31:0] LOG_OFFSET  = 32'd4096;

    reg [31:0] candidate;
    reg in_region;

    always @* begin
        candidate = 32'd0;
        in_region = 1'b0;
        case (region)
            2'd0: if (index < 13'd8) begin
                candidate = (directory_b ? DIRECTORY_B : DIRECTORY_A)
                          + {19'd0, index};
                in_region = 1'b1;
            end
            2'd1: if (slot < 3'd6 && index < 13'd4096) begin
                candidate = SLOT_BASE + ({29'd0, slot} * SLOT_SIZE)
                          + {19'd0, index};
                in_region = 1'b1;
            end
            2'd2: if (slot < 3'd6 && index < 13'd4096) begin
                candidate = SLOT_BASE + ({29'd0, slot} * SLOT_SIZE)
                          + LOG_OFFSET + {19'd0, index};
                in_region = 1'b1;
            end
            default: begin end
        endcase
        valid = in_region && (candidate < sector_count);
        lba = valid ? candidate : 32'd0;
    end
endmodule
