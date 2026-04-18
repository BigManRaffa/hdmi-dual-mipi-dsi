// frame_splitter.sv
// Takes the HDMI pixel stream and steers each line's left half (pixels 0-1279)
// into one FIFO and the right half (pixels 1280-2559) into another.  Pixels
// are packed 4-at-a-time into a 96-bit word so downstream 4-lane DSI TX can
// consume one group every 3 byte_clk cycles with no alignment fuss.
//
// Pixel convention  : 24-bit {B[7:0], G[7:0], R[7:0]}   (R is LSB of pixel)
// Packed word layout: [23:0]=pix0, [47:24]=pix1, [71:48]=pix2, [95:72]=pix3
// -> byte N of group = word[8*N+7 : 8*N]
import dsi_pkg::*;

module frame_splitter (
  input  logic        pclk,
  input  logic        rst_n,

  // HDMI-side pixel input (DE-gated, active high sync).
  input  logic [23:0] pix_rgb,
  input  logic        pix_de,
  input  logic        pix_vs,
  input  logic        pix_hs,

  // Two pixel-FIFO write ports (96 bit = 4 pixels).
  output logic        left_wr_en,
  output logic [95:0] left_wr_data,
  input  logic        left_full,

  output logic        right_wr_en,
  output logic [95:0] right_wr_data,
  input  logic        right_full,

  // For diagnostics / simulation only.
  output logic        overflow
);

  localparam int HALF = HDMI_H_ACTIVE / 2;  // 1280

  // pixel-position counter (resets between active lines)
  logic [11:0] x_count;
  always_ff @(posedge pclk or negedge rst_n) begin
    if (!rst_n)              x_count <= '0;
    else if (!pix_de)        x_count <= '0;
    else                     x_count <= x_count + 12'd1;
  end

  // 4-pixel packer
  // We store pixels 0, 1, 2 of a group in regs; pixel 3 is taken straight
  // from pix_rgb when we write the FIFO in that cycle.
  logic [23:0] p0, p1, p2;
  always_ff @(posedge pclk) begin
    if (pix_de) begin
      unique case (x_count[1:0])
        2'd0: p0 <= pix_rgb;
        2'd1: p1 <= pix_rgb;
        2'd2: p2 <= pix_rgb;
        default: ;   // pixel 3 is written into FIFO directly
      endcase
    end
  end

  wire [95:0] group = {pix_rgb, p2, p1, p0};
  wire        grp_stb = pix_de && (x_count[1:0] == 2'd3);
  wire        is_left  = (x_count < HALF);
  wire        is_right = ~is_left && (x_count < HDMI_H_ACTIVE);

  assign left_wr_data  = group;
  assign left_wr_en    = grp_stb && is_left;

  assign right_wr_data = group;
  assign right_wr_en   = grp_stb && is_right;

  // overflow detector (simulation aid)
  logic ovf;
  always_ff @(posedge pclk or negedge rst_n) begin
    if (!rst_n)                                     ovf <= 1'b0;
    else if ((left_wr_en && left_full) ||
             (right_wr_en && right_full))           ovf <= 1'b1;
  end
  assign overflow = ovf;

  // Silence unused-input warnings.
  wire _unused = &{pix_vs, pix_hs, 1'b0};

endmodule
