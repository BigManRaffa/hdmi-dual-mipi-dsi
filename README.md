# hdmi_to_dual_dsi

Hello! this is an HDMI to dual-MIPI-DSI bridge, my friend Tino needed one and I decided to spend a couple hours of my day to make it. Takes one 2560x1600@60 HDMI input, splits each line down the middle, and pumps the two halves out on two independent 4-lane MIPI DSI links (1280x1600 each). Protocol is non-burst video mode with sync pulses, RGB888-packed (DT 0x3E).

If you came here looking for a clean reference implementation of a MIPI DSI video-mode packetizer, I guess this is okay. If you're trying to drive a dual-link panel from an HDMI source, this is the protocol engine between the two sides. Wire it up to your own HDMI RX and MIPI D-PHY wrappers and go!

## What's in the box

```
rtl/
  dsi_pkg.sv          constants (MIPI data types, timing)
  dsi_ecc.sv          24->6 packet-header ECC (MIPI spec Table 24)
  dsi_crc16.sv        CRC-16-CCITT, 4 bytes/cycle combinational fold
  async_fifo.sv       Gray-code dual-clock FIFO (pclk -> byte_clk)
  frame_splitter.sv   pclk side, packs 4 pixels into a 96-bit FIFO entry
  dsi_video_tx.sv     byte_clk side, emits VSS/VSE/HSS + RGB long packets
  hdmi_to_dual_dsi.sv core top, splitter + 2 FIFOs + 2 video TX
  dsi_bridge_top.sv   synth-ready universal top with internal test pattern
tb/
  tb_hdmi_to_dual_dsi.sv   self-checking testbench (Verilator or iverilog)
```

## Run the sim

```bash
verilator --binary --timing -Irtl \
  -Wno-UNOPTFLAT -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-UNUSEDSIGNAL \
  rtl/*.sv tb/tb_hdmi_to_dual_dsi.sv --top-module tb_hdmi_to_dual_dsi -o tbsim
./obj_dir/tbsim
```

Finishes in under a second, you should see:

```
PASS: CRC16 verified over 3840 payload bytes (CRC=491a)
  *** ALL CHECKS PASSED ***
```

What the tb does: drives synthetic HDMI timing with a gradient pattern, captures every byte the left link emits, checks VSS/VSE/HSS DIs and ECCs, checks the RGB header bytes, captures all 3840 payload bytes and folds its own CRC16 over them to compare against what the DUT emits on cycle 981.

Icarus Verilog works too if you don't have Verilator:

```bash
iverilog -g2012 -Irtl -o tb.vvp rtl/*.sv tb/tb_hdmi_to_dual_dsi.sv
vvp tb.vvp
```

Way slower (minutes instead of seconds), but same result.

You can also run the tb inside Vivado if that's your vibe. Add `tb/tb_hdmi_to_dual_dsi.sv` as a simulation source, set it as the simulation top, then Flow Navigator -> SIMULATION -> Run Simulation -> Run Behavioral Simulation. The `$display` output shows up in the Tcl Console. Slower than Verilator but sometimes handy if you're already in Vivado debugging something and don't wanna switch tools.

## Synthesize it

Set `dsi_bridge_top` as the top module. That's a ready-to-synth wrapper that puts an internal test pattern generator inline as the HDMI source and exposes only slow status signals (heartbeat LED, SOF pulses, sticky underflow/overflow) externally. Keeps all the 268 MHz and 147.9 MHz action internal to the FPGA so timing actually closes on hobby boards.

Tested on Xilinx Spartan-7 (xc7s50csga324-1) in Vivado 2025.2. Synth results:

- 5262 / 32600 Slice LUTs (16%)
- 373 / 65200 Slice FFs (<1%)
- 0 errors, 0 critical warnings

Should port cleanly to Artix-7, Kintex-7, Zynq-7000, UltraScale+ or any Xilinx/AMD part. On Intel, Lattice, Microchip, the RTL itself works but you'll need to swap the PLL primitive in your board shim for the vendor equivalent.

### Clock constraints (Xilinx XDC)

```tcl
create_clock -period 3.728 -name pclk     [get_ports pclk]
create_clock -period 6.760 -name byte_clk [get_ports byte_clk]
set_clock_groups -asynchronous \
  -group [get_clocks pclk] \
  -group [get_clocks byte_clk]
```

Ratio byte_clk:pclk must be exactly 1500:2720 so HDMI pixel rate matches DSI consumption rate. Generate both off the same MMCM/PLL to keep them phase-locked.

## What FPGA do I need

Short answer: depends how far you want to take it.

### Just run sim and synth to prove it works

Any Xilinx FPGA with Vivado installed. Tested on Arty S7-50 but any -50 or bigger Spartan/Artix-7 class part has room. You can also run synth on CrossLink-NX, Zynq, whatever, it's 16% of an S7-50 so fitting isn't the issue.

### Actually drive a panel (the real deal!)

You need three things working together:

1. **HDMI input path.** Real HDMI is TMDS differential at around 2.67 Gbps/lane for this resolution. Options:
   - External HDMI RX chip (ADV7611, TFP401A) feeding parallel RGB into the FPGA
   - Native TMDS decode in FPGA fabric via IOSERDES + PLL
   - Hard HDMI macros (newer high-end parts only)

2. **MIPI DSI output path.** 1.18 Gbps/lane serial, needs MIPI D-PHY:
   - External D-PHY bridge chip (SN65DSI83/84, TC358775)
   - Native D-PHY-capable LVDS I/O + IOSERDES
   - Hard D-PHY blocks

3. **An FPGA with enough high-speed I/O** for both of the above.

Realistic board options:

- **Lattice CrossLink-NX (LIFCL-40-EVN)** around $100. Lattice literally markets this as a bridging FPGA. Hardened MIPI D-PHY built in, 4 lanes per interface up to 2.5 Gbps/lane. No external D-PHY chip needed. Would need an HDMI RX add-on board. Best value for this specific use case.
- **Digilent Nexys Video** around $460. Artix-7 XC7A200T with on-board HDMI IN + HDMI OUT, plenty of LVDS on FMC. External D-PHY bridge on a daughterboard required.
- **Digilent Zybo Z7-20** around $300. Zynq-7020, HDMI IN + OUT on board, Pmod connectors for D-PHY add-on.
- **ZCU102 / ZCU104** ($2K-$4K). Zynq UltraScale+ MPSoC with hard MIPI D-PHY. Overkill for hobby but what actual products ship on.

### Porting to your board

The only board-specific file is `dsi_bridge_top.sv` (well, a shim around it). It takes three inputs: `pclk` (around 268 MHz), `byte_clk` (around 147.9 MHz), and `rst_n`. Generate the two clocks off your board's reference clock using the same PLL/MMCM so the 2720:1500 ratio stays exact.

Pin constraints go in whatever format your vendor uses:
- Xilinx: XDC
- Intel: QSF (Quartus Settings File)
- Lattice: LPF (Lattice Preference File)
- Microchip: PDC

## How it actually works

Using a little funny trick. 4 pixels packed into one 96-bit FIFO entry = 12 bytes = exactly 3 byte_clk cycles of 4-lane output. No alignment skew, no barrel shifters, just one counter that cycles 0->1->2->0 and reads a different 32-bit slice each phase.

**frame_splitter** (pclk side) watches HDMI pixels come in, counts x_count while DE is high. Every 4 pixels it concatenates them into a 96-bit word and writes to the left FIFO (x<1280) or right FIFO (x>=1280). Entry layout matches wire order for DT 0x3E, so lane 0 byte 0 is always the R channel of the first pixel:

```
entry[7:0]   = R of pixel 0
entry[15:8]  = G of pixel 0
entry[23:16] = B of pixel 0
entry[31:24] = R of pixel 1
...
```

**dsi_video_tx** (byte_clk side) runs two counters, cycle_in_line (0-1499) and line_idx (0-1639). Per line:

```
cycle 0        short packet (VSS if line=0, VSE if line=6, else HSS)
cycle 1-19     idle (HBP-ish gap so the D-PHY wrapper has room for LP->HS)
cycle 20       RGB long-packet header: DI=0x3E, WC_lo=0x00, WC_hi=0x0F, ECC
cycle 21-980   payload, 960 cycles x 4 bytes = 3840 bytes = 1280 px x 3
cycle 981      CRC16_lo, CRC16_hi, 0, 0  (pad on lanes 2-3)
cycle 982+     idle
```

The payload works via a 2-bit grp_phase counter. Phase 0 emits bytes [31:0] of the current FIFO head, phase 1 [63:32], phase 2 [95:64]. On phase 2 we also pulse pfifo_rd_en so the next cycle reads the next group. 320 groups x 3 cycles each = 960 payload cycles per line. No prefetch register, no separate FSM state, just a counter and a mux.

CRC16 folds 4 bytes per byte_clk during the payload, resets to 0xFFFF on the header cycle. Poly x^16+x^12+x^5+1, init 0xFFFF, LSB-first, no output reflection, no final XOR (= CCITT with reversed poly 0x8408).

Frame structure:

```
line 0          VSS
line 1-5        HSS
line 6          VSE
line 7-36       HSS        (VSYNC + VBP = 37 lines before active)
line 37-1636    HSS + RGB  (1600 active lines)
line 1637-1639  HSS        (VFP = 3 lines)
```

## Stuff this core doesn't do

- **LP<->HS transitions, HS-prepare/trail** live in your D-PHY wrapper. lane_valid tells the wrapper where the HS bytes are, wrapper pads the gaps.
- **EoTP** (DT 0x08). Most modern panels don't need it. Easy to add if yours does, allocate 4 extra cycles at end-of-line.
- **Command mode / DCS init**. Video mode only. Panel init sequences happen out-of-band through your wrapper's LP path.
- **BTA / reverse reads**. No backchannel here, no point.

## Some things to consider

1. **No frame sync between HDMI and DSI.** The core free-runs on each clock. Real integration should add a frame_start pulse on byte_clk that resets cycle_in_line/line_idx to 0. Generate from HDMI vsync edge, 2-flop sync into each byte_clk domain, feed it in. About 15 lines to add.

2. **Right link starts empty on first active line.** HDMI streams left half first (cols 0-1279) then right half (1280-2559), so when both DSI links hit their first payload cycle, left FIFO has around 57 groups queued but right FIFO is empty. `dsi_bridge_top` handles this by staggering the right-link reset by one HDMI line. Alternative is a line-buffered splitter.

3. **Driving 268 MHz HDMI or 147 MHz DSI through regular FPGA pins won't close timing on mid-range parts.** Those paths need IOSERDES + differential pairs, or a board with dedicated high-speed I/O. `dsi_bridge_top` keeps everything internal to avoid this.

## Trust anchors

Hand-verified ECC values before writing anything:
- DI=0x01 (VSS) -> ECC 0x07
- DI=0x11 (VSE) -> ECC 0x14
- DI=0x21 (HSS) -> ECC 0x12
- RGB header 0x0F003E -> ECC 0x01

CRC16 vectors verified in Python:
- CRC16(empty) = 0xFFFF
- CRC16({0xFF, 0xFF}) = 0x0000

Then the tb folds its own CRC16 over captured payload bytes and compares against the DUT. If any of that ever breaks, something real is wrong.

## License

MIT.