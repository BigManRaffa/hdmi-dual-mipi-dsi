// hdmi_to_dual_dsi.sv
// Top level.  Takes one 2560x1600@60 HDMI pixel stream (decoded RGB888
// already, we don't do TMDS) and drives two independent MIPI DSI transmitters,
// each pushing a 1280x1600 half-frame on 4 lanes in non-burst video mode.
//
// [HDMI pclk] -> frame_splitter -> {left_fifo, right_fifo} -> [byte_clk] ->
//                                    {dsi_video_tx_L, dsi_video_tx_R} -> D-PHY
//
// Clocks:
// pclk      around 268 MHz   (HDMI 2560x1600 @ 60 Hz CVT-RB-ish)
// byte_clk  around 147.6 MHz (DSI byte clock; the two links can share one
//                               net or each have their own, whichever's easier)
import dsi_pkg::*;

module hdmi_to_dual_dsi #(
  parameter int FIFO_DEPTH_LOG2 = 10        // 1024 x 96-bit entries / FIFO
) (
  // HDMI-side pixel stream
  input  logic                    pclk,
  input  logic                    pclk_rst_n,
  input  logic [23:0]             hdmi_rgb,    // {B,G,R} with R at LSB
  input  logic                    hdmi_de,
  input  logic                    hdmi_vs,
  input  logic                    hdmi_hs,

  // DSI-side byte clocks
  input  logic                    byte_clk_l,
  input  logic                    byte_clk_r,
  input  logic                    byte_rst_n_l,
  input  logic                    byte_rst_n_r,

  // Left DSI link (half-frame 0-1279)
  // lane0=[7:0], lane1=[15:8], lane2=[23:16], lane3=[31:24]
  output logic [31:0]             left_lane_data,
  output logic                    left_lane_valid,
  output logic                    left_hs_req,
  output logic                    left_sof,
  output logic                    left_underflow,

  // Right DSI link (half-frame 1280-2559)
  output logic [31:0]             right_lane_data,
  output logic                    right_lane_valid,
  output logic                    right_hs_req,
  output logic                    right_sof,
  output logic                    right_underflow,

  // Diagnostics
  output logic                    splitter_overflow
);

  // Frame splitter and FIFO write ports
  logic        left_wr_en,  right_wr_en;
  logic [95:0] left_wr_data, right_wr_data;
  logic        left_full,    right_full;

  frame_splitter u_splitter (
    .pclk          (pclk),
    .rst_n         (pclk_rst_n),
    .pix_rgb       (hdmi_rgb),
    .pix_de        (hdmi_de),
    .pix_vs        (hdmi_vs),
    .pix_hs        (hdmi_hs),
    .left_wr_en    (left_wr_en),
    .left_wr_data  (left_wr_data),
    .left_full     (left_full),
    .right_wr_en   (right_wr_en),
    .right_wr_data (right_wr_data),
    .right_full    (right_full),
    .overflow      (splitter_overflow)
  );

  // Two async FIFOs (one per DSI link)
  logic [95:0] left_rd_data,  right_rd_data;
  logic        left_empty,    right_empty;
  logic        left_rd_en,    right_rd_en;

  async_fifo #(.WIDTH(96), .DEPTH_LOG2(FIFO_DEPTH_LOG2)) u_fifo_l (
    .wr_clk   (pclk),
    .wr_rst_n (pclk_rst_n),
    .wr_en    (left_wr_en),
    .wr_data  (left_wr_data),
    .full     (left_full),
    .rd_clk   (byte_clk_l),
    .rd_rst_n (byte_rst_n_l),
    .rd_en    (left_rd_en),
    .rd_data  (left_rd_data),
    .empty    (left_empty)
  );

  async_fifo #(.WIDTH(96), .DEPTH_LOG2(FIFO_DEPTH_LOG2)) u_fifo_r (
    .wr_clk   (pclk),
    .wr_rst_n (pclk_rst_n),
    .wr_en    (right_wr_en),
    .wr_data  (right_wr_data),
    .full     (right_full),
    .rd_clk   (byte_clk_r),
    .rd_rst_n (byte_rst_n_r),
    .rd_en    (right_rd_en),
    .rd_data  (right_rd_data),
    .empty    (right_empty)
  );

  // Two DSI video transmitters
  dsi_video_tx u_dsi_l (
    .byte_clk      (byte_clk_l),
    .rst_n         (byte_rst_n_l),
    .pfifo_rd_data (left_rd_data),
    .pfifo_empty   (left_empty),
    .pfifo_rd_en   (left_rd_en),
    .lane_data     (left_lane_data),
    .lane_valid    (left_lane_valid),
    .hs_req        (left_hs_req),
    .sof           (left_sof),
    .underflow     (left_underflow)
  );

  dsi_video_tx u_dsi_r (
    .byte_clk      (byte_clk_r),
    .rst_n         (byte_rst_n_r),
    .pfifo_rd_data (right_rd_data),
    .pfifo_empty   (right_empty),
    .pfifo_rd_en   (right_rd_en),
    .lane_data     (right_lane_data),
    .lane_valid    (right_lane_valid),
    .hs_req        (right_hs_req),
    .sof           (right_sof),
    .underflow     (right_underflow)
  );

endmodule
