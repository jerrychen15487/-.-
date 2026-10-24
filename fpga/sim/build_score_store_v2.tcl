set_device -name GW5AT-60B GW5AT-LV60PG484AC1/I0
add_file -type verilog "src/uart_rx.v"
add_file -type verilog "src/score_uart_tx.v"
add_file -type verilog "src/score_uart_v2_transport.v"
add_file -type verilog "src/sd_storage_lba.v"
add_file -type verilog "src/sd_spi_block_device.v"
add_file -type verilog "src/sd_directory_mount.v"
add_file -type verilog "src/sd_directory_image.v"
add_file -type verilog "src/sd_directory_copy_write.v"
add_file -type verilog "src/sd_score_block_verify.v"
add_file -type verilog "src/sd_score_progress_scan.v"
add_file -type verilog "src/sd_score_block_write.v"
add_file -type verilog "src/sd_score_file_validate.v"
add_file -type verilog "src/score_store_v2.v"
set_option -top_module score_store_v2
set_option -verilog_std v2001
set_option -output_base_name score_store_v2_check
set_option -vccx 1.8
run syn
