// tb_hdmi_to_dual_dsi.sv
// Self-checking testbench.  Uses realistic HDMI timing so the HDMI pixel
// production rate matches the DSI consumption rate; runs long enough to
// verify one full RGB long packet on the left link.
`timescale 1ns/1ps
import dsi_pkg::*;

module tb_hdmi_to_dual_dsi;

  // HDMI timing constants (matched to DSI frame rate)
  localparam int HDMI_H_TOTAL = 2720;
  localparam int HDMI_H_ACT   = HDMI_H_ACTIVE;   // 2560
  localparam int HDMI_V_TOTAL = 1640;            // match DSI for rate lock
  localparam int HDMI_V_ACT   = HDMI_V_ACTIVE;   // 1600
  // Align HDMI's active region exactly with DSI's so HDMI writes and DSI
  // reads are in the same phase of the frame.
  localparam int HDMI_V_START = V_ACTIVE_START;

  // Clocks & resets
  // byte_clk / pclk = 1500/2720 exactly -> HDMI pixel rate matches DSI rate.
  // pclk half-period = 1.864 ns (268.24 MHz).  Tbyte = Tpclk * 2720/1500.
  logic pclk     = 1'b0;
  logic byte_clk = 1'b0;
  always #1.864 pclk     = ~pclk;                 // 268.24 MHz
  always #3.380 byte_clk = ~byte_clk;              // 147.93 MHz (exact ratio)

  logic pclk_rst_n      = 1'b0;
  logic byte_rst_n_l    = 1'b0;
  logic byte_rst_n_r    = 1'b0;

  // HDMI pattern source
  logic [23:0] hdmi_rgb;
  logic        hdmi_de;
  logic        hdmi_vs, hdmi_hs;
  logic [11:0] hx;
  logic [11:0] hy;

  always_ff @(posedge pclk or negedge pclk_rst_n) begin
    if (!pclk_rst_n) begin
      hx <= '0;  hy <= '0;
    end else begin
      if (hx == HDMI_H_TOTAL-1) begin
        hx <= '0;
        hy <= (hy == HDMI_V_TOTAL-1) ? 12'd0 : (hy + 12'd1);
      end else
        hx <= hx + 12'd1;
    end
  end

  wire hdmi_active_line = (hy >= HDMI_V_START) && (hy < HDMI_V_START + HDMI_V_ACT);
  wire hdmi_active_col  = (hx < HDMI_H_ACT);
  assign hdmi_de   = pclk_rst_n && hdmi_active_line && hdmi_active_col;
  assign hdmi_vs   = 1'b0;
  assign hdmi_hs   = 1'b0;
  assign hdmi_rgb  = {(hx[7:0] ^ hy[7:0]), hy[7:0], hx[7:0]};

  // DUT (smaller FIFO for faster sim)
  logic [31:0] l_data,  r_data;
  logic        l_valid, r_valid;
  logic        l_hs,    r_hs;
  logic        l_sof,   r_sof;
  logic        l_uf,    r_uf;
  logic        ovf;

  hdmi_to_dual_dsi #(.FIFO_DEPTH_LOG2(9)) dut (  // 512-entry FIFOs
    .pclk            (pclk),
    .pclk_rst_n      (pclk_rst_n),
    .hdmi_rgb        (hdmi_rgb),
    .hdmi_de         (hdmi_de),
    .hdmi_vs         (hdmi_vs),
    .hdmi_hs         (hdmi_hs),
    .byte_clk_l      (byte_clk),
    .byte_clk_r      (byte_clk),
    .byte_rst_n_l    (byte_rst_n_l),
    .byte_rst_n_r    (byte_rst_n_r),
    .left_lane_data  (l_data),
    .left_lane_valid (l_valid),
    .left_hs_req     (l_hs),
    .left_sof        (l_sof),
    .left_underflow  (l_uf),
    .right_lane_data (r_data),
    .right_lane_valid(r_valid),
    .right_hs_req    (r_hs),
    .right_sof       (r_sof),
    .right_underflow (r_uf),
    .splitter_overflow(ovf)
  );

  // DSI line/cycle tracker (mirrors DUT internal)
  int          cyc_in_line;
  int          line_idx;
  int          errors;
  logic [7:0]  payload [$];        // captured RGB payload bytes
  logic [15:0] captured_crc;
  logic        have_captured_payload = 0;

  initial begin
    cyc_in_line  = 0;
    line_idx     = 0;
    errors       = 0;
    payload.delete();
  end

  task check_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("[%0t] FAIL: %s  got=%08h exp=%08h  (line=%0d cyc=%0d)",
               $time, what, got, exp, line_idx, cyc_in_line);
      errors++;
    end
  endtask

  always @(posedge byte_clk) begin
    if (!byte_rst_n_l) begin
      cyc_in_line <= 0;
      line_idx    <= 0;
    end else if (cyc_in_line == CYCLES_PER_LINE - 1) begin
      cyc_in_line <= 0;
      line_idx    <= (line_idx == V_TOTAL-1) ? 0 : (line_idx + 1);
    end else begin
      cyc_in_line <= cyc_in_line + 1;
    end
  end

  logic [7:0] b0, b1, b2, b3;
  always_comb begin
    b0 = l_data[7:0];
    b1 = l_data[15:8];
    b2 = l_data[23:16];
    b3 = l_data[31:24];
  end

  localparam int RGB_START     = CYCLES_HBP_WAIT;
  localparam int RGB_PAY_FIRST = RGB_START + 1;
  localparam int RGB_PAY_LAST  = RGB_START + RGB_PAYLOAD_CYCLES;
  localparam int RGB_CRC_CYC   = RGB_PAY_LAST + 1;

  always @(posedge byte_clk) begin
    if (byte_rst_n_l && l_valid) begin

      if (line_idx == 0 && cyc_in_line == 0) begin
        check_eq("VSS DI",  b0, 8'h01);
        check_eq("VSS d0",  b1, 8'h00);
        check_eq("VSS d1",  b2, 8'h00);
        check_eq("VSS ECC", b3, 8'h07);
      end

      if (line_idx == V_VSE_LINE && cyc_in_line == 0) begin
        check_eq("VSE DI",  b0, 8'h11);
        check_eq("VSE d0",  b1, 8'h00);
        check_eq("VSE d1",  b2, 8'h00);
        check_eq("VSE ECC", b3, 8'h14);
      end

      if (line_idx == 1 && cyc_in_line == 0) begin
        check_eq("HSS DI",  b0, 8'h21);
        check_eq("HSS d0",  b1, 8'h00);
        check_eq("HSS d1",  b2, 8'h00);
        check_eq("HSS ECC", b3, 8'h12);
      end

      if (line_idx == V_ACTIVE_START) begin
        if (cyc_in_line == 0) begin
          check_eq("active HSS DI",  b0, 8'h21);
          check_eq("active HSS ECC", b3, 8'h12);
        end
        if (cyc_in_line == RGB_START) begin
          check_eq("RGB  DI",  b0, 8'h3E);
          check_eq("RGB  WC0", b1, 8'h00);
          check_eq("RGB  WC1", b2, 8'h0F);
          check_eq("RGB  ECC", b3, 8'h01);
        end
        if (cyc_in_line >= RGB_PAY_FIRST && cyc_in_line <= RGB_PAY_LAST) begin
          payload.push_back(b0);
          payload.push_back(b1);
          payload.push_back(b2);
          payload.push_back(b3);
        end
        if (cyc_in_line == RGB_CRC_CYC && !have_captured_payload) begin
          have_captured_payload <= 1'b1;
          captured_crc          <= {b1, b0};
          if (b2 !== 8'h00) begin
            $display("[%0t] FAIL: CRC pad byte 2 = %02h", $time, b2);
            errors++;
          end
          if (b3 !== 8'h00) begin
            $display("[%0t] FAIL: CRC pad byte 3 = %02h", $time, b3);
            errors++;
          end
        end
      end

      if (line_idx == V_ACTIVE_START + 1 && cyc_in_line == 0) begin
        check_eq("next line HSS DI",  b0, 8'h21);
        check_eq("next line HSS ECC", b3, 8'h12);
      end
    end
  end

  // Stimulus
  initial begin
    #20 pclk_rst_n <= 1'b1;
    // LEFT: released together with pclk. HDMI left-half data (pixels 0-1279)
    // is already streaming by the time DSI LEFT reaches cyc 21 of line 37.
    #4 byte_rst_n_l <= 1'b1;
    // RIGHT: staggered by ~1 HDMI line (10.14us) so DSI RIGHT's line 37 cyc 21
    // coincides with HDMI producing line 37's right-half pixels.  Otherwise
    // the RIGHT FIFO is empty during the first DSI active line.  The two DSI
    // outputs end up offset in time by one DSI line; downstream panels expect
    // this kind of phase offset for dual-link input.
    #10_140 byte_rst_n_r <= 1'b1;
    #395_000;
    done_task();
  end

  task done_task;
    logic [15:0] exp_crc; logic xv; logic [7:0] bt;
    begin
      if (have_captured_payload) begin
        exp_crc = 16'hFFFF;
        for (int i = 0; i < payload.size(); i++) begin
          bt = payload[i];
          for (int b = 0; b < 8; b++) begin
            xv      = exp_crc[0] ^ bt[b];
            exp_crc = exp_crc >> 1;
            if (xv) exp_crc = exp_crc ^ 16'h8408;
          end
        end
        if (exp_crc !== captured_crc) begin
          $display("[%0t] FAIL: CRC mismatch  got=%04h  exp=%04h  (over %0d bytes)",
                   $time, captured_crc, exp_crc, payload.size());
          errors++;
        end else begin
          $display("[%0t] PASS: CRC16 verified over %0d payload bytes (CRC=%04h)",
                   $time, payload.size(), captured_crc);
        end
        if (payload.size() != RGB_PAYLOAD_BYTES) begin
          $display("[%0t] FAIL: captured payload length %0d != %0d",
                   $time, payload.size(), RGB_PAYLOAD_BYTES);
          errors++;
        end
      end else begin
        $display("[%0t] FAIL: never saw the RGB CRC cycle", $time);
        errors++;
      end

      if (l_uf) begin $display("FAIL: left_underflow asserted");   errors++; end
      if (r_uf) begin $display("FAIL: right_underflow asserted");  errors++; end
      if (ovf)  begin $display("FAIL: splitter_overflow asserted"); errors++; end

      if (errors == 0) $display("\n  *** ALL CHECKS PASSED ***\n");
      else             $display("\n  *** %0d FAILURE(S) ***\n", errors);
      $finish;
    end
  endtask

endmodule
