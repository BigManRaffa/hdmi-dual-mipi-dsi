# Clock constraints for dsi_bridge_top
# pclk      : HDMI pixel clock, 268.24 MHz (2560x1600 @ 60 Hz, Htotal=2720)
# byte_clk  : DSI byte clock,  147.93 MHz (shared between both DSI links)
# Ratio byte_clk : pclk = 1500 : 2720 exactly, so HDMI pixel rate matches
# DSI consumption rate.

create_clock -period 3.728 -name pclk     [get_ports pclk]
create_clock -period 6.760 -name byte_clk [get_ports byte_clk]

# HDMI and DSI domains cross only through the Gray-code async FIFOs, which
# handle the CDC safely. Tell the tool not to try to close timing between them.
set_clock_groups -asynchronous \
  -group [get_clocks pclk] \
  -group [get_clocks byte_clk]