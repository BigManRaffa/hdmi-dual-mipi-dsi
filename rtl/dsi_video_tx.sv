// dsi_video_tx.sv
// The 4-lane MIPI DSI video-mode packetizer.  Emits non-burst video mode
// with sync pulses:
// VSS (0x01)  on line 0          cycle 0
// VSE (0x11)  on line V_VSE_LINE cycle 0
// HSS (0x21)  on every other line cycle 0
// RGB888-packed (0x3E) long packet on every active line, starting at
// cycle CYCLES_HBP_WAIT and lasting RGB_TOTAL_CYCLES byte_clks.
//
// Pixel stream source: 96-bit-wide async FIFO (4 packed pixels per entry).
// group[7:0]=R0 [15:8]=G0 [23:16]=B0 [31:24]=R1 ... (see frame_splitter).
// One 96-bit entry feeds exactly 3 byte_clk cycles of 4-lane output (12
// bytes) which is why this whole design works out so clean.
//
// Lane data is a flat 32-bit bus: byte N of a cycle goes on lane N and
// lives in lane_data[8*N+7 : 8*N].  Flat bus means the interface stays
// portable across simulators and whatever's downstream.
//
// What's NOT in here: LP<->HS transitions, EoTP, BTA, command mode.  All
// of that belongs in the D-PHY wrapper. lane_valid/hs_req just tell the
// wrapper where the HS bytes live.
import dsi_pkg::*;

module dsi_video_tx (
  input  logic                     byte_clk,
  input  logic                     rst_n,

  // pixel FIFO (read side)
  input  logic [95:0]              pfifo_rd_data,
  input  logic                     pfifo_empty,
  output logic                     pfifo_rd_en,

  // 4-lane parallel byte stream (to D-PHY wrapper)
  // lane0 = [7:0], lane1 = [15:8], lane2 = [23:16], lane3 = [31:24]
  output logic [31:0]              lane_data,
  output logic                     lane_valid,
  output logic                     hs_req,

  // diagnostics
  output logic                     sof,        // pulse at frame start
  output logic                     underflow   // sticky
);

  // Timing constants (all derived from dsi_pkg)
  localparam int RGB_START     = CYCLES_HBP_WAIT;                   // 20
  localparam int RGB_PAY_FIRST = RGB_START + 1;                     // 21
  localparam int RGB_PAY_LAST  = RGB_START + RGB_PAYLOAD_CYCLES;    // 980
  localparam int RGB_CRC_CYC   = RGB_PAY_LAST + 1;                  // 981

  // Primary counters:
  // cycle_in_line [0 .. CYCLES_PER_LINE-1]
  // line_idx      [0 .. V_TOTAL-1]
  logic [10:0] cycle_in_line;
  logic [10:0] line_idx;

  wire end_of_line  = (cycle_in_line == CYCLES_PER_LINE-1);
  wire end_of_frame = end_of_line && (line_idx == V_TOTAL-1);

  always_ff @(posedge byte_clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_in_line <= '0;
      line_idx      <= '0;
    end else begin
      if (end_of_line) begin
        cycle_in_line <= '0;
        line_idx      <= end_of_frame ? 11'd0 : (line_idx + 11'd1);
      end else begin
        cycle_in_line <= cycle_in_line + 11'd1;
      end
    end
  end

  assign sof = (cycle_in_line == 0) && (line_idx == 0);

  // Region decoders
  wire in_active_line = (line_idx >= V_ACTIVE_START) && (line_idx < V_ACTIVE_END);

  wire is_short_cyc   = (cycle_in_line == 0);                      // VSS/VSE/HSS
  wire is_rgb_hdr     = in_active_line && (cycle_in_line == RGB_START);
  wire is_rgb_payload = in_active_line &&
                        (cycle_in_line >= RGB_PAY_FIRST) &&
                        (cycle_in_line <= RGB_PAY_LAST);
  wire is_rgb_crc     = in_active_line && (cycle_in_line == RGB_CRC_CYC);

  // Short-packet generation (VSS on line 0, VSE on line V_VSE_LINE, else HSS)
  logic [5:0] short_dt;
  always_comb begin
    if      (line_idx == 11'd0)            short_dt = DT_VSS;
    else if (line_idx == V_VSE_LINE[10:0]) short_dt = DT_VSE;
    else                                   short_dt = DT_HSS;
  end
  wire [7:0]  short_di  = {VC, short_dt};          // {VC, DT}
  wire [23:0] short_hdr = {16'h0000, short_di};
  logic [7:0] short_ecc;
  dsi_ecc u_ecc_short (.hdr(short_hdr), .ecc(short_ecc));

  // RGB long-packet header (DI, WC[7:0], WC[15:8], ECC).  WC = 3840 = 0x0F00.
  localparam logic [15:0] RGB_WC = RGB_PAYLOAD_BYTES[15:0];
  wire [7:0]  rgb_di  = {VC, DT_RGB888_PACKED};
  wire [23:0] rgb_hdr = {RGB_WC, rgb_di};
  logic [7:0] rgb_ecc;
  dsi_ecc u_ecc_rgb (.hdr(rgb_hdr), .ecc(rgb_ecc));

  // Group-phase counter: which 32-bit slice of the 96-bit FIFO entry we're on.
  // phase 0 -> data[31:0] phase 1 -> [63:32] phase 2 -> [95:64]
  // Resets to 0 on the RGB header cycle so that the first payload cycle is
  // phase 0.  Rolls 0->1->2->0 during payload.  On phase-2 cycles we also
  // pulse pfifo_rd_en to advance to the next 4-pixel group.
  logic [1:0] grp_phase;
  always_ff @(posedge byte_clk or negedge rst_n) begin
    if (!rst_n)              grp_phase <= 2'd0;
    else if (is_rgb_hdr)     grp_phase <= 2'd0;
    else if (is_rgb_payload) grp_phase <= (grp_phase == 2'd2) ? 2'd0
                                                              : (grp_phase + 2'd1);
  end

  logic [31:0] slice_cur;
  always_comb begin
    unique case (grp_phase)
      2'd0:    slice_cur = pfifo_rd_data[31:0];
      2'd1:    slice_cur = pfifo_rd_data[63:32];
      2'd2:    slice_cur = pfifo_rd_data[95:64];
      default: slice_cur = 32'h0;
    endcase
  end

  assign pfifo_rd_en = is_rgb_payload && (grp_phase == 2'd2);

  // CRC-16 over the 3840 payload bytes.  Reset to 0xFFFF on the header cycle,
  // fold 4 payload bytes per cycle during payload.
  logic [15:0] crc_acc;
  logic [15:0] crc_next;
  dsi_crc16 #(.NBYTES(4)) u_crc (
    .crc_in (crc_acc),
    .data   (slice_cur),           // 4 bytes (data[0]=slice_cur[7:0])
    .valid  (4'b1111),
    .crc_out(crc_next)
  );

  always_ff @(posedge byte_clk or negedge rst_n) begin
    if      (!rst_n)         crc_acc <= 16'hFFFF;
    else if (is_rgb_hdr)     crc_acc <= 16'hFFFF;
    else if (is_rgb_payload) crc_acc <= crc_next;
  end

  // Output mux: build each lane byte, then concatenate into flat 32-bit bus.
  // lane_data = {lane3, lane2, lane1, lane0}
  logic [7:0] b0, b1, b2, b3;
  always_comb begin
    b0 = 8'h00; b1 = 8'h00; b2 = 8'h00; b3 = 8'h00;
    lane_valid = 1'b0;

    if (is_short_cyc) begin
      b0 = short_di;
      b1 = 8'h00;
      b2 = 8'h00;
      b3 = short_ecc;
      lane_valid = 1'b1;
    end else if (is_rgb_hdr) begin
      b0 = rgb_di;
      b1 = RGB_WC[7:0];
      b2 = RGB_WC[15:8];
      b3 = rgb_ecc;
      lane_valid = 1'b1;
    end else if (is_rgb_payload) begin
      b0 = slice_cur[7:0];
      b1 = slice_cur[15:8];
      b2 = slice_cur[23:16];
      b3 = slice_cur[31:24];
      lane_valid = 1'b1;
    end else if (is_rgb_crc) begin
      b0 = crc_acc[7:0];
      b1 = crc_acc[15:8];
      b2 = 8'h00;                  // pad
      b3 = 8'h00;                  // pad
      lane_valid = 1'b1;
    end
  end

  assign lane_data = {b3, b2, b1, b0};
  assign hs_req    = lane_valid;

  // Underflow: sticky flag if the FIFO was empty when we needed pixel data.
  logic uf;
  always_ff @(posedge byte_clk or negedge rst_n) begin
    if (!rst_n)                                              uf <= 1'b0;
    else if ((is_rgb_hdr || is_rgb_payload) && pfifo_empty)  uf <= 1'b1;
  end
  assign underflow = uf;

endmodule
