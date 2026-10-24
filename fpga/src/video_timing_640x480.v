module video_timing_640x480 (
    input  wire       pixel_clk,
    input  wire       rst_n,
    output reg        hsync,
    output reg        vsync,
    output reg        de,
    output reg [9:0]  pix_x,
    output reg [9:0]  pix_y
);
    localparam H_ACTIVE = 640;
    localparam H_FRONT  = 16;
    localparam H_SYNC   = 96;
    localparam H_TOTAL  = 800;
    localparam V_ACTIVE = 480;
    localparam V_FRONT  = 10;
    localparam V_SYNC   = 2;
    localparam V_TOTAL  = 525;
    reg [9:0] h_count;
    reg [9:0] v_count;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
        end else if (h_count == H_TOTAL - 1) begin
            h_count <= 10'd0;
            if (v_count == V_TOTAL - 1)
                v_count <= 10'd0;
            else
                v_count <= v_count + 1'b1;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end

    always @(*) begin
        de = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);
        hsync = ~((h_count >= H_ACTIVE + H_FRONT) &&
                  (h_count < H_ACTIVE + H_FRONT + H_SYNC));
        vsync = ~((v_count >= V_ACTIVE + V_FRONT) &&
                  (v_count < V_ACTIVE + V_FRONT + V_SYNC));
        pix_x = de ? h_count : 10'd0;
        pix_y = de ? v_count : 10'd0;
    end
endmodule
