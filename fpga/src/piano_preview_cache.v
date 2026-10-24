// Freeze the first 20 committed NOTE records as inexpensive pixel geometry.
// One multiplier/mapping path is shared across records at load time; the HDMI
// renderer only sees stable coordinates after loaded=1.
module piano_preview_cache (
    input wire clk,rst_n,clear,
    input wire note_valid,
    input wire [31:0] note_index,start_tick,duration_tick,
    input wire [6:0] pitch,
    input wire [1:0] part_mask,
    input wire read_done,read_available,
    input wire [15:0] read_bpm,
    output reg loaded,
    output reg [15:0] bpm,
    output wire [31:0] loop_ticks,
    output reg [19:0] valid_mask,
    output reg [239:0] start_px_bus,length_px_bus,
    output reg [199:0] x_left_bus,x_right_bus,
    output reg [39:0] part_bus
);
    reg [31:0] full_end_tick;
    reg pending_valid,read_done_q,read_available_q;
    reg [4:0] pending_index;
    reg [31:0] pending_start_tick,pending_duration_tick;
    reg [6:0] pending_pitch;
    reg [1:0] pending_part_mask;
    reg [15:0] read_bpm_q;
    // The preview clock and score matcher both cover the same 20 NOTE records.
    // Later NOTE records are decoded but cannot advance this visible excerpt.
    assign loop_ticks=full_end_tick;
    function [19:0] x_bounds;
        input [6:0] note_pitch;
        begin
            case(note_pitch)
                7'd21:x_bounds={10'd11,10'd1};
                7'd22:x_bounds={10'd16,10'd8};
                7'd23:x_bounds={10'd23,10'd13};
                7'd24:x_bounds={10'd35,10'd25};
                7'd25:x_bounds={10'd40,10'd32};
                7'd26:x_bounds={10'd48,10'd37};
                7'd27:x_bounds={10'd53,10'd45};
                7'd28:x_bounds={10'd60,10'd50};
                7'd29:x_bounds={10'd72,10'd62};
                7'd30:x_bounds={10'd77,10'd69};
                7'd31:x_bounds={10'd85,10'd74};
                7'd32:x_bounds={10'd90,10'd82};
                7'd33:x_bounds={10'd97,10'd87};
                7'd34:x_bounds={10'd102,10'd94};
                7'd35:x_bounds={10'd109,10'd99};
                7'd36:x_bounds={10'd122,10'd111};
                7'd37:x_bounds={10'd127,10'd119};
                7'd38:x_bounds={10'd134,10'd124};
                7'd39:x_bounds={10'd139,10'd131};
                7'd40:x_bounds={10'd146,10'd136};
                7'd41:x_bounds={10'd159,10'd148};
                7'd42:x_bounds={10'd164,10'd156};
                7'd43:x_bounds={10'd171,10'd161};
                7'd44:x_bounds={10'd176,10'd168};
                7'd45:x_bounds={10'd183,10'd173};
                7'd46:x_bounds={10'd188,10'd180};
                7'd47:x_bounds={10'd195,10'd185};
                7'd48:x_bounds={10'd208,10'd197};
                7'd49:x_bounds={10'd213,10'd205};
                7'd50:x_bounds={10'd220,10'd210};
                7'd51:x_bounds={10'd225,10'd217};
                7'd52:x_bounds={10'd232,10'd222};
                7'd53:x_bounds={10'd245,10'd234};
                7'd54:x_bounds={10'd250,10'd242};
                7'd55:x_bounds={10'd257,10'd247};
                7'd56:x_bounds={10'd262,10'd254};
                7'd57:x_bounds={10'd269,10'd259};
                7'd58:x_bounds={10'd274,10'd266};
                7'd59:x_bounds={10'd282,10'd271};
                7'd60:x_bounds={10'd294,10'd284};
                7'd61:x_bounds={10'd299,10'd291};
                7'd62:x_bounds={10'd306,10'd296};
                7'd63:x_bounds={10'd311,10'd303};
                7'd64:x_bounds={10'd319,10'd308};
                7'd65:x_bounds={10'd331,10'd321};
                7'd66:x_bounds={10'd336,10'd328};
                7'd67:x_bounds={10'd343,10'd333};
                7'd68:x_bounds={10'd348,10'd340};
                7'd69:x_bounds={10'd355,10'd345};
                7'd70:x_bounds={10'd360,10'd352};
                7'd71:x_bounds={10'd368,10'd357};
                7'd72:x_bounds={10'd380,10'd370};
                7'd73:x_bounds={10'd385,10'd377};
                7'd74:x_bounds={10'd392,10'd382};
                7'd75:x_bounds={10'd397,10'd389};
                7'd76:x_bounds={10'd405,10'd394};
                7'd77:x_bounds={10'd417,10'd407};
                7'd78:x_bounds={10'd422,10'd414};
                7'd79:x_bounds={10'd429,10'd419};
                7'd80:x_bounds={10'd434,10'd426};
                7'd81:x_bounds={10'd442,10'd431};
                7'd82:x_bounds={10'd447,10'd439};
                7'd83:x_bounds={10'd454,10'd444};
                7'd84:x_bounds={10'd466,10'd456};
                7'd85:x_bounds={10'd471,10'd463};
                7'd86:x_bounds={10'd479,10'd468};
                7'd87:x_bounds={10'd484,10'd476};
                7'd88:x_bounds={10'd491,10'd481};
                7'd89:x_bounds={10'd503,10'd493};
                7'd90:x_bounds={10'd508,10'd500};
                7'd91:x_bounds={10'd515,10'd505};
                7'd92:x_bounds={10'd520,10'd512};
                7'd93:x_bounds={10'd528,10'd517};
                7'd94:x_bounds={10'd533,10'd525};
                7'd95:x_bounds={10'd540,10'd530};
                7'd96:x_bounds={10'd552,10'd542};
                7'd97:x_bounds={10'd557,10'd549};
                7'd98:x_bounds={10'd565,10'd554};
                7'd99:x_bounds={10'd570,10'd562};
                7'd100:x_bounds={10'd577,10'd567};
                7'd101:x_bounds={10'd589,10'd579};
                7'd102:x_bounds={10'd594,10'd586};
                7'd103:x_bounds={10'd602,10'd591};
                7'd104:x_bounds={10'd607,10'd599};
                7'd105:x_bounds={10'd614,10'd604};
                7'd106:x_bounds={10'd619,10'd611};
                7'd107:x_bounds={10'd626,10'd616};
                7'd108:x_bounds={10'd639,10'd628};
                default:x_bounds=20'd0;
            endcase
        end
    endfunction
    wire [19:0] mapped_bounds=x_bounds(pending_pitch);
    wire [9:0] mapped_x_left=mapped_bounds[9:0];
    wire [9:0] mapped_x_right=mapped_bounds[19:10];
    wire [43:0] start_product=pending_start_tick*12'd3291;
    wire [43:0] length_product=pending_duration_tick*12'd3291;
    wire [11:0] mapped_start=start_product[43:28]!=0 ? 12'hfff :
        start_product[27:16];
    wire [11:0] mapped_length=length_product[43:28]!=0 ? 12'hfff :
        length_product[27:16]<4 ? 12'd4:length_product[27:16];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            loaded<=0;bpm<=0;full_end_tick<=0;valid_mask<=0;
            start_px_bus<=0;length_px_bus<=0;
            x_left_bus<=0;x_right_bus<=0;part_bus<=0;
            pending_valid<=0;pending_index<=0;
            pending_start_tick<=0;pending_duration_tick<=0;
            pending_pitch<=0;pending_part_mask<=0;
            read_done_q<=0;read_available_q<=0;read_bpm_q<=0;
        end else if(clear) begin
            loaded<=0;bpm<=0;full_end_tick<=0;valid_mask<=0;
            pending_valid<=0;read_done_q<=0;
        end else begin
            // Isolate the decoder's pitch/valid path from the wide preview
            // register-bank enables. Geometry is written one clock later.
            pending_valid<=note_valid && note_index<20 &&
                pitch>=21 && pitch<=108 && part_mask!=0;
            pending_index<=note_index[4:0];
            pending_start_tick<=start_tick;
            pending_duration_tick<=duration_tick;
            pending_pitch<=pitch;
            pending_part_mask<=part_mask;
            if(note_valid && note_index<20 &&
               start_tick+duration_tick>full_end_tick)
                full_end_tick<=start_tick+duration_tick;
            read_done_q<=read_done;
            read_available_q<=read_available;
            read_bpm_q<=read_bpm;
            if(pending_valid) begin
                valid_mask[pending_index]<=1;
                start_px_bus[pending_index*12 +:12]<=mapped_start;
                length_px_bus[pending_index*12 +:12]<=mapped_length;
                x_left_bus[pending_index*10 +:10]<=mapped_x_left;
                x_right_bus[pending_index*10 +:10]<=mapped_x_right;
                part_bus[pending_index*2 +:2]<=pending_part_mask;
            end
            if(read_done_q) begin
                // Include a final record that arrives alongside read_done.
                loaded<=read_available_q && (valid_mask!=0 || pending_valid);
                bpm<=read_bpm_q;
            end
        end
    end
endmodule
