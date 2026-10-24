set_device -name GW5AT-60B GW5AT-LV60PG484AC1/I0
add_file -type verilog "src/sd_storage_lba.v"
add_file -type verilog "src/sd_score_block_verify.v"
add_file -type verilog "src/sd_score_progress_scan.v"
set_option -top_module sd_score_progress_scan
set_option -verilog_std v2001
set_option -output_base_name sd_score_progress_scan_check
set_option -vccx 1.8
run syn
