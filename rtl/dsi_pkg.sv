// dsi_pkg.sv
// All the MIPI DSI constants in one place: data type codes, timing params,
// lane/pixel packing numbers.  Spec references are MIPI Alliance DSI v1.1
// and v1.3.
`ifndef DSI_PKG_SV
`define DSI_PKG_SV

package dsi_pkg;

  // Data Type codes (Processor -> Peripheral, MIPI DSI spec)
  localparam logic [5:0] DT_VSS  = 6'h01;  // V Sync Start
  localparam logic [5:0] DT_VSE  = 6'h11;  // V Sync End
  localparam logic [5:0] DT_HSS  = 6'h21;  // H Sync Start
  localparam logic [5:0] DT_HSE  = 6'h31;  // H Sync End
  localparam logic [5:0] DT_EOTP = 6'h08;  // End of Transmission packet
  localparam logic [5:0] DT_RGB888_PACKED = 6'h3E;  // 24bpp packed pixel stream

  // Resolution / timing defaults
  // Full HDMI input: 2560x1600 @ 60Hz CVT-RB-ish (Htotal=2720, Vtotal=1637)
  localparam int HDMI_H_ACTIVE = 2560;
  localparam int HDMI_V_ACTIVE = 1600;

  // Per DSI link: 1280 x 1600 (half-frame). Chosen output timing:
  //   Htot=1440, Vtot=1640.  byte_clk target is around or equal to 147.6 MHz for 60 Hz.
  localparam int DSI_H_ACTIVE = 1280;
  localparam int DSI_H_FP     = 48;
  localparam int DSI_H_SYNC   = 32;
  localparam int DSI_H_BP     = 80;   // total H = 1440

  localparam int DSI_V_ACTIVE = 1600;
  localparam int DSI_V_FP     = 3;
  localparam int DSI_V_SYNC   = 6;
  localparam int DSI_V_BP     = 31;   // total V = 1640

  // Lane / pixel packing
  localparam int NUM_LANES    = 4;
  localparam int BYTES_PER_PIXEL = 3;

  // For 1280 active pixels, 3 bytes/pixel, 4 lanes:
  //   payload bytes = 3840  (exact multiple of 4 -> 960 byte_clk cycles)
  //   header        = 4     (1 byte_clk cycle)
  //   CRC           = 2     (half of a cycle; we pad remaining 2 lane slots)
  localparam int RGB_PAYLOAD_BYTES   = DSI_H_ACTIVE * BYTES_PER_PIXEL; // 3840
  localparam int RGB_PAYLOAD_CYCLES  = RGB_PAYLOAD_BYTES / NUM_LANES;  // 960
  localparam int RGB_TOTAL_CYCLES    = 1 + RGB_PAYLOAD_CYCLES + 1;     // 962
                                       // (header + payload + crc-with-pad)

  // Frame/line timing in byte_clk cycles. A byte_clk of ~147.6 MHz gives
  // 60 Hz at V_TOTAL=1640 lines with CYCLES_PER_LINE=1500 byte_clk cycles.
  localparam int CYCLES_PER_LINE = 1500;
  localparam int CYCLES_HBP_WAIT = 20;   // LP-to-HS gap after HSS short packet

  localparam int V_TOTAL = DSI_V_SYNC + DSI_V_BP + DSI_V_ACTIVE + DSI_V_FP;
  // Active region: [V_ACTIVE_START, V_ACTIVE_END)
  localparam int V_ACTIVE_START = DSI_V_SYNC + DSI_V_BP;
  localparam int V_ACTIVE_END   = V_ACTIVE_START + DSI_V_ACTIVE;
  localparam int V_VSE_LINE     = DSI_V_SYNC;  // line on which VSE is sent

  // Virtual channel default
  localparam logic [1:0] VC = 2'b00;

  // Convenience!
  function automatic logic [7:0] make_di(input logic [1:0] vc,
                                         input logic [5:0] dt);
    return {vc, dt};
  endfunction

endpackage : dsi_pkg

`endif
