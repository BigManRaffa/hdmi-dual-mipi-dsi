// dsi_ecc.sv
// Packet-header ECC for MIPI DSI (24-bit input, 6 parity bits, Hamming-
// modified).  Feed it the 24-bit header {byte2, byte1, DI} in wire byte
// order and you get 8 bits back (top two are zero, low six are P5-P0).
// Formulas come straight out of MIPI DSI spec v1.1 Table 24.
// Sanity-checked against test vector: 0x009c21 -> ECC 0x1E.
module dsi_ecc (
  input  logic [23:0] hdr,
  output logic [7:0]  ecc
);

  logic p0, p1, p2, p3, p4, p5;

  assign p0 = hdr[0]  ^ hdr[1]  ^ hdr[2]  ^ hdr[4]  ^ hdr[5]  ^ hdr[7]  ^
              hdr[10] ^ hdr[11] ^ hdr[13] ^ hdr[16] ^ hdr[20] ^ hdr[21] ^
              hdr[22] ^ hdr[23];

  assign p1 = hdr[0]  ^ hdr[1]  ^ hdr[3]  ^ hdr[4]  ^ hdr[6]  ^ hdr[8]  ^
              hdr[10] ^ hdr[12] ^ hdr[14] ^ hdr[17] ^ hdr[20] ^ hdr[21] ^
              hdr[22] ^ hdr[23];

  assign p2 = hdr[0]  ^ hdr[2]  ^ hdr[3]  ^ hdr[5]  ^ hdr[6]  ^ hdr[9]  ^
              hdr[11] ^ hdr[12] ^ hdr[15] ^ hdr[18] ^ hdr[20] ^ hdr[21] ^
              hdr[22];

  assign p3 = hdr[1]  ^ hdr[2]  ^ hdr[3]  ^ hdr[7]  ^ hdr[8]  ^ hdr[9]  ^
              hdr[13] ^ hdr[14] ^ hdr[15] ^ hdr[19] ^ hdr[20] ^ hdr[21] ^
              hdr[23];

  assign p4 = hdr[4]  ^ hdr[5]  ^ hdr[6]  ^ hdr[7]  ^ hdr[8]  ^ hdr[9]  ^
              hdr[16] ^ hdr[17] ^ hdr[18] ^ hdr[19] ^ hdr[20] ^ hdr[22] ^
              hdr[23];

  assign p5 = hdr[10] ^ hdr[11] ^ hdr[12] ^ hdr[13] ^ hdr[14] ^ hdr[15] ^
              hdr[16] ^ hdr[17] ^ hdr[18] ^ hdr[19] ^ hdr[21] ^ hdr[22] ^
              hdr[23];

  assign ecc = {2'b00, p5, p4, p3, p2, p1, p0};

endmodule
