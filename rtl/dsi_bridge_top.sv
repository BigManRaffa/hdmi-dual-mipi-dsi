// dsi_bridge_top.sv
// A board-agnostic top-level wrapper around hdmi_to_dual_dsi.  The idea here is
// to keep everything interesting internal to the FPGA so timing can actually
// close on most hobby boards: instead of piping 268 MHz HDMI and 147 MHz DSI
// in/out through external pins, we use an internal test-pattern generator as
// the HDMI source and expose only a slow status interface (4 LEDs) externally.
//
// Board-specific stuff (PLL for 268 MHz + 147.9 MHz from the board's reference
// clock, pin names) is NOT in here.  You write a tiny board shim that:
// 1. Takes whatever reference clock your board has
// 2. Generates pclk and byte_clk (ratio 2720:1500 exactly)
// 3. Instantiates this module
// 4. Wires up reset and LED pins
// See the bottom of this file for a sketch of what the board shim looks like
// for Arty S7, Nexys Video, CrossLink-NX etc.
//
// Once you're ready to drive a real panel, swap the tpg source for a real HDMI
// RX and route lane_data / lane_valid out through a D-PHY wrapper.

import dsi_pkg::*;

module dsi_bridge_top (
  // Universal interface: the board shim wires these from pins/PLLs
  input  logic pclk,              // around 268 MHz   (HDMI pixel clock)
  input  logic byte_clk,          // around 147.9 MHz (DSI byte clock, shared L/R)
  input  logic rst_n,             // active-low reset, synced to both domains externally

  // Status outputs the board shim can route to LEDs / headers / ILA
  output logic        heartbeat,        // blinks at around 1 Hz, proves the thing is alive
  output logic        status_sof_l,     // left  frame start pulse
  output logic        status_sof_r,     // right frame start pulse
  output logic        status_underflow, // sticky: FIFO underflowed at some point
  output logic        status_overflow,  // sticky: FIFO overflowed at some point

  // DSI byte streams: normally you'd route these to a D-PHY wrapper.  On a
  // board without D-PHY, leave these unconnected and probe via ILA instead.
  output logic [31:0] left_lane_data,
  output logic        left_lane_valid,
  output logic [31:0] right_lane_data,
  output logic        right_lane_valid
);

  // Internal HDMI test-pattern generator
  // Drives synthetic 2720 x 1640 timing with DE high for 2560 px on 1600 lines.
  // Gradient pattern: R = x, G = y, B = x ^ y.  Matches the self-test mode in
  // the Verilator testbench so hardware captures should look identical.
  logic [11:0] hx, hy;
  logic [23:0] tpg_rgb;
  logic        tpg_de, tpg_vs, tpg_hs;

  always_ff @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
      hx <= '0;
      hy <= '0;
    end else if (hx == 12'd2719) begin
      hx <= '0;
      hy <= (hy == 12'd1639) ? 12'd0 : (hy + 12'd1);
    end else begin
      hx <= hx + 12'd1;
    end
  end

  // Active region aligned with DSI's so HDMI writes and DSI reads stay in phase
  wire   hdmi_active_col  = (hx < 12'd2560);
  wire   hdmi_active_line = (hy >= V_ACTIVE_START) && (hy < V_ACTIVE_END);
  assign tpg_de  = hdmi_active_col && hdmi_active_line;
  assign tpg_vs  = (hy < 12'd6);
  assign tpg_hs  = (hx < 12'd32);
  assign tpg_rgb = {(hx[7:0] ^ hy[7:0]), hy[7:0], hx[7:0]};

  // Stagger the right-link reset by one HDMI line so its first payload read
  // lines up with when HDMI is producing right-half pixels. See README.
  // At 147.9 MHz byte_clk this is around 1500 cycles of delay.
  logic [10:0] right_rst_ctr;
  logic        rst_n_right;
  always_ff @(posedge byte_clk or negedge rst_n) begin
    if (!rst_n) begin
      right_rst_ctr <= '0;
      rst_n_right   <= 1'b0;
    end else if (right_rst_ctr == 11'd1500) begin
      rst_n_right   <= 1'b1;
    end else begin
      right_rst_ctr <= right_rst_ctr + 11'd1;
    end
  end

  // The actual bridge
  logic [31:0] l_data, r_data;
  logic        l_valid, r_valid;
  logic        l_hs,    r_hs;
  logic        l_sof,   r_sof;
  logic        l_uf,    r_uf;
  logic        ovf;

  hdmi_to_dual_dsi #(.FIFO_DEPTH_LOG2(9)) u_dut (
    .pclk             (pclk),
    .pclk_rst_n       (rst_n),
    .hdmi_rgb         (tpg_rgb),
    .hdmi_de          (tpg_de),
    .hdmi_vs          (tpg_vs),
    .hdmi_hs          (tpg_hs),
    .byte_clk_l       (byte_clk),
    .byte_clk_r       (byte_clk),
    .byte_rst_n_l     (rst_n),
    .byte_rst_n_r     (rst_n_right),
    .left_lane_data   (l_data),
    .left_lane_valid  (l_valid),
    .left_hs_req      (l_hs),
    .left_sof         (l_sof),
    .left_underflow   (l_uf),
    .right_lane_data  (r_data),
    .right_lane_valid (r_valid),
    .right_hs_req     (r_hs),
    .right_sof        (r_sof),
    .right_underflow  (r_uf),
    .splitter_overflow(ovf)
  );

  // Route lane streams to top-level outputs (board shim can ignore these or
  // probe them with an ILA or route to D-PHY).
  assign left_lane_data   = l_data;
  assign left_lane_valid  = l_valid;
  assign right_lane_data  = r_data;
  assign right_lane_valid = r_valid;

  // Status outputs: heartbeat LED, per-link SOF pulses, sticky fault flags.
  // These are slow enough to route through any FPGA's regular I/O pins.
  logic [26:0] heartbeat_ctr;
  always_ff @(posedge byte_clk or negedge rst_n) begin
    if (!rst_n) heartbeat_ctr <= '0;
    else        heartbeat_ctr <= heartbeat_ctr + 27'd1;
  end
  assign heartbeat        = heartbeat_ctr[26];  // ~1.1 Hz blink at 147.9 MHz
  assign status_sof_l     = l_sof;
  assign status_sof_r     = r_sof;
  assign status_underflow = l_uf | r_uf;
  assign status_overflow  = ovf;

endmodule

// Example board shim (not compiled; just a reference).
// Drop this into a separate file like arty_s7_shim.sv and wire to pins via XDC.
//
// module arty_s7_shim (
//   input  logic       clk100,       // Arty S7 on-board 100 MHz clock (pin E3)
//   input  logic       btn_rst_n,    // pushbutton, active low when pressed
//   output logic [3:0] led           // four on-board LEDs
// );
//   logic pclk, byte_clk, mmcm_locked;
//
//   // Clocking Wizard IP generating pclk (268.24 MHz) and byte_clk (147.93 MHz)
//   // off the same VCO so the 2720:1500 ratio is exact.  Both out of the same
//   // MMCM, both on BUFGs.
//   clk_wiz_0 u_mmcm (
//     .clk_in1 (clk100),
//     .clk_out1(pclk),
//     .clk_out2(byte_clk),
//     .locked  (mmcm_locked),
//     .resetn  (btn_rst_n)
//   );
//
//   wire rst_n = btn_rst_n & mmcm_locked;
//
//   logic hb, sof_l, sof_r, uf, ovf;
//
//   dsi_bridge_top u_top (
//     .pclk            (pclk),
//     .byte_clk        (byte_clk),
//     .rst_n           (rst_n),
//     .heartbeat       (hb),
//     .status_sof_l    (sof_l),
//     .status_sof_r    (sof_r),
//     .status_underflow(uf),
//     .status_overflow (ovf),
//     // Unused on Arty S7, tie off so synth doesn't complain
//     .left_lane_data  (),
//     .left_lane_valid (),
//     .right_lane_data (),
//     .right_lane_valid()
//   );
//
//   assign led = {ovf, uf, sof_l | sof_r, hb};
// endmodule
