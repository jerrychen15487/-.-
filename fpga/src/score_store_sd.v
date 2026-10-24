// Physical SD wrapper. The controller is separately testable against a
// fault-injectable block-device model; the board uses this real SPI device.
module score_store_sd #(
    parameter MAX_SLOTS=6
) (
    input wire clk,rst_n,uart_rx,sd_miso,
    output wire uart_tx,sd_cs_n,sd_sck,sd_mosi,
    output wire storage_ready,
    output wire [31:0] catalog_generation,
    input wire preview_request,
    output wire preview_done,preview_available,preview_note_valid,
    output wire [31:0] preview_note_index,preview_start_tick,
    output wire [31:0] preview_duration_tick,
    output wire [6:0] preview_pitch,
    output wire [1:0] preview_part_mask,
    output wire preview_score_onset,
    output wire preview_score_hold,preview_score_velocity,
    output wire [2:0] preview_dynamic,
    output wire [15:0] preview_bpm,
    input wire page_request,
    input wire [1:0] page_notation,
    input wire [5:0] page_index,
    input wire [15:0] page_request_token,
    output wire page_begin,page_done,page_available,page_byte_valid,
    output wire [5:0] page_selected_index,
    output wire [15:0] page_completed_token,
    output wire [3:0] page_result,
    output wire [15:0] page_byte_index,
    output wire [7:0] page_byte,
    output wire page_diag_err_valid,page_diag_err_page_found,
        page_diag_err_index_clear,page_diag_pub_valid,
    output wire [2:0] page_diag_err_state,
    output wire [31:0] page_diag_err_length,page_diag_err_offset,
        page_diag_err_total,page_diag_pub_length,
        page_diag_pub_byte_offset,
    output wire [4:0] page_diag_pub_page_field
);
    wire dev_ready,dev_init_done,dev_done;
    wire [7:0] dev_error,dev_rdata;
    wire [31:0] sector_count,dev_lba;
    wire [8:0] dev_addr;
    wire [7:0] dev_wdata;
    wire dev_we,dev_start,dev_write,dev_guard;
    sd_spi_block_device device (
        .clk(clk),.rst_n(rst_n),.miso(sd_miso),
        .cs_n(sd_cs_n),.sck(sd_sck),.mosi(sd_mosi),
        .req_start(dev_start),.req_write(dev_write),
        .req_guard_valid(dev_guard),.req_lba(dev_lba),
        .ready(dev_ready),.init_done(dev_init_done),.done(dev_done),
        .error_code(dev_error),.sector_count(sector_count),
        .buffer_addr(dev_addr),.buffer_wdata(dev_wdata),
        .buffer_we(dev_we),.buffer_rdata(dev_rdata)
    );
    score_store_v2 #(.MAX_SLOTS(MAX_SLOTS)) controller (
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .dev_ready(dev_ready),.dev_init_done(dev_init_done),
        .dev_done(dev_done),.dev_error(dev_error),
        .dev_rdata(dev_rdata),.sector_count(sector_count),
        .dev_addr(dev_addr),.dev_wdata(dev_wdata),
        .dev_we(dev_we),.dev_start(dev_start),
        .dev_write(dev_write),.dev_guard(dev_guard),
        .dev_lba(dev_lba),.storage_ready(storage_ready),
        .catalog_generation(catalog_generation),
        .preview_request(preview_request),.preview_done(preview_done),
        .preview_available(preview_available),
        .preview_note_valid(preview_note_valid),
        .preview_note_index(preview_note_index),
        .preview_start_tick(preview_start_tick),
        .preview_duration_tick(preview_duration_tick),
        .preview_pitch(preview_pitch),
        .preview_part_mask(preview_part_mask),
        .preview_score_onset(preview_score_onset),
        .preview_score_hold(preview_score_hold),
        .preview_score_velocity(preview_score_velocity),
        .preview_dynamic(preview_dynamic),
        .preview_bpm(preview_bpm),
        .page_request(page_request),.page_notation(page_notation),
        .page_index(page_index),.page_selected_index(page_selected_index),
        .page_request_token(page_request_token),
        .page_completed_token(page_completed_token),
        .page_begin(page_begin),.page_done(page_done),
        .page_available(page_available),.page_result(page_result),
        .page_byte_valid(page_byte_valid),
        .page_byte_index(page_byte_index),.page_byte(page_byte),
        .page_diag_err_valid(page_diag_err_valid),
        .page_diag_err_page_found(page_diag_err_page_found),
        .page_diag_err_index_clear(page_diag_err_index_clear),
        .page_diag_err_state(page_diag_err_state),
        .page_diag_err_length(page_diag_err_length),
        .page_diag_err_offset(page_diag_err_offset),
        .page_diag_err_total(page_diag_err_total),
        .page_diag_pub_valid(page_diag_pub_valid),
        .page_diag_pub_length(page_diag_pub_length),
        .page_diag_pub_byte_offset(page_diag_pub_byte_offset),
        .page_diag_pub_page_field(page_diag_pub_page_field)
    );
endmodule
