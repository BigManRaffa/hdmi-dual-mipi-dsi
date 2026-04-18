// dsi_crc16.sv
// CRC-16 over the MIPI DSI long-packet payload.  It's CRC-16-CCITT:
// Polynomial : x^16 + x^12 + x^5 + 1
// Init       : 0xFFFF
// Bit order  : LSB of each byte first (so reversed polynomial = 0x8408)
// Output     : not reflected, no final XOR
// Spec runs this byte-serial but we fold up to 4 bytes per byte_clk so the
// 4-lane payload stream doesn't have to stall.  Combinational; the accumulator
// register lives up in the packetizer where it belongs.
module dsi_crc16 #(
  parameter int NBYTES = 4
) (
  input  logic [15:0]      crc_in,
  input  logic [NBYTES-1:0][7:0] data,
  input  logic [NBYTES-1:0] valid,      // per-byte valid (MSB-indexed byte last)
  output logic [15:0]      crc_out
);

  // Per-byte combinational update (LSB bit of byte shifted in first).
  function automatic logic [15:0] upd8(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] x;
    logic        v;
    x = c;
    for (int i = 0; i < 8; i++) begin
      v = x[0] ^ b[i];
      x = x >> 1;
      if (v) x = x ^ 16'h8408;
    end
    return x;
  endfunction

  logic [15:0] stage [NBYTES:0];

  assign stage[0] = crc_in;
  genvar g;
  generate
    for (g = 0; g < NBYTES; g++) begin : g_stage
      // Skip bytes whose "valid" bit is 0 (used on the last cycle when CRC/pad
      // bytes are being emitted and we don't want them folded into the CRC).
      assign stage[g+1] = valid[g] ? upd8(stage[g], data[g]) : stage[g];
    end
  endgenerate

  assign crc_out = stage[NBYTES];

endmodule
