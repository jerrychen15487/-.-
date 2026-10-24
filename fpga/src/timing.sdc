create_clock -name sys_clk -period 20.000 -waveform {0 10.000} [get_ports {sys_clk}]
create_generated_clock -name pixel_clk -source [get_ports {sys_clk}] -multiply_by 1 -divide_by 2 [get_pins {u_video_pll/u_plla/CLKOUT0}]
create_generated_clock -name serial_clk -source [get_ports {sys_clk}] -multiply_by 5 -divide_by 2 [get_pins {u_video_pll/u_plla/CLKOUT1}]

# The audio/control domain and HDMI PLL domain exchange only a bundled-data
# snapshot through a synchronized toggle.  Treat those CDC paths as
# asynchronous; pixel_clk and serial_clk remain related to each other.
set_false_path -from [get_clocks {sys_clk}] -to [get_clocks {pixel_clk}]
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {sys_clk}]

# OSER10 RESET is an asynchronous primitive input (UG304, section 4.3.5).
# It is asserted during video reset and released from a pixel-clocked register;
# exclude only these three one-time reset paths from recovery/removal analysis.
set_false_path -to [get_pins {*u_oser10/RESET}]
