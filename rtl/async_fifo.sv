// async_fifo.sv
// Dual-clock async FIFO with Gray-coded pointers and 2-flop CDC synchronizers.
// Power-of-two depth only.  Memory is simple behavioral dual-port stuff, so it
// infers as BRAM on FPGA and you'd swap it for a dual-port SRAM macro on ASIC
// (or just flops for small depths).
module async_fifo #(
  parameter int WIDTH       = 96,
  parameter int DEPTH_LOG2  = 10           // 1024 entries
) (
  // write clock domain
  input  logic              wr_clk,
  input  logic              wr_rst_n,
  input  logic              wr_en,
  input  logic [WIDTH-1:0]  wr_data,
  output logic              full,

  // read clock domain
  input  logic              rd_clk,
  input  logic              rd_rst_n,
  input  logic              rd_en,
  output logic [WIDTH-1:0]  rd_data,
  output logic              empty
);

  localparam int DEPTH = 1 << DEPTH_LOG2;

  // Memory (inferred dual-port RAM).
  logic [WIDTH-1:0] mem [DEPTH];

  // Binary + Gray pointers, both wr-domain and rd-domain.
  logic [DEPTH_LOG2:0] wr_bin, wr_bin_next, wr_gray, wr_gray_next;
  logic [DEPTH_LOG2:0] rd_bin, rd_bin_next, rd_gray, rd_gray_next;

  // CDC pointer shadows.
  logic [DEPTH_LOG2:0] wr_gray_rd_q1, wr_gray_rd_q2; // write ptr in rd domain
  logic [DEPTH_LOG2:0] rd_gray_wr_q1, rd_gray_wr_q2; // read  ptr in wr domain

  // write side
  // "what the pointer would be if we DO write this cycle"; used for full
  // detection.  It's independent of 'full' itself, breaking the comb loop.
  wire [DEPTH_LOG2:0] wr_bin_p1   = wr_bin + 1'b1;
  wire [DEPTH_LOG2:0] wr_gray_p1  = (wr_bin_p1 >> 1) ^ wr_bin_p1;

  assign wr_bin_next  = wr_bin + (wr_en && !full);
  assign wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_bin  <= '0;
      wr_gray <= '0;
    end else begin
      wr_bin  <= wr_bin_next;
      wr_gray <= wr_gray_next;
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_en && !full) mem[wr_bin[DEPTH_LOG2-1:0]] <= wr_data;
  end

  // Synchronize read-pointer Gray into write domain.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      rd_gray_wr_q1 <= '0;
      rd_gray_wr_q2 <= '0;
    end else begin
      rd_gray_wr_q1 <= rd_gray;
      rd_gray_wr_q2 <= rd_gray_wr_q1;
    end
  end

  // Full condition: if we WERE to write this cycle, the new write pointer
  // would collide (in Gray code, top-two bits inverted from the synchronized
  // read pointer, rest equal).
  wire [DEPTH_LOG2:0] full_check = {~rd_gray_wr_q2[DEPTH_LOG2:DEPTH_LOG2-1],
                                     rd_gray_wr_q2[DEPTH_LOG2-2:0]};
  assign full = (wr_gray_p1 == full_check);

  // read side
  assign rd_bin_next  = rd_bin + (rd_en && !empty);
  assign rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_bin  <= '0;
      rd_gray <= '0;
    end else begin
      rd_bin  <= rd_bin_next;
      rd_gray <= rd_gray_next;
    end
  end

  // Synchronize write-pointer Gray into read domain.
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      wr_gray_rd_q1 <= '0;
      wr_gray_rd_q2 <= '0;
    end else begin
      wr_gray_rd_q1 <= wr_gray;
      wr_gray_rd_q2 <= wr_gray_rd_q1;
    end
  end

  // Use combinational read. BRAM-style read would add a cycle of latency.
  // For a BRAM-backed version, add a registered rd_data and assert rd_en one
  // cycle ahead.  For this reference design, behavioral is fine.
  assign rd_data = mem[rd_bin[DEPTH_LOG2-1:0]];
  assign empty   = (wr_gray_rd_q2 == rd_gray);

endmodule
