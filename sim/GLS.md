# Gate-level simulation of croc_soc

`sim/scripts/run_gls.sh <program.hex> [work dir]` simulates the final netlist (`outputs/latest/croc_soc.v`)
with Verilator, zero delay, using the repo testbench. It patches copies of the testbench, netlist and cell
models in the work directory; the repo is not touched. See the script header for the patches and why.

## What works

- Program: `sim/sw/gls_mini/build.sh` builds a 272-byte program that prints `GLS OK` on the UART and fits the
  2 KB SRAM. It needs `riscv64-unknown-elf-gcc` (on Rocky: build it on the Mac and copy `bin/gls_mini.hex`).
- RTL passes with this program, and so does the gate-level netlist with the same timestamps (`GLS OK` at
  914450 ns, finish at 934200 ns) when the flop output delay is 0.5 ns (`FLOPDELAY`, the default). With 0.1 ns the
  core diverged after the wake-up: the vendor SRAM model samples address and data at CLK + 100 ps, the instant
  a 0.1 ns flop delay changes them, so stores were corrupted. Keep `FLOPDELAY` above that window.
- Unit delay on all gates runs Verilator out of memory. Formality is the tool for equivalence.

## Chip-level gate-level simulation (pads included)

`scripts/gls/run_chip_gls.sh <chip_top.pnl.v> <croc_soc.v> [work dir]` simulates the placed chip netlist of the template
(pad ring + `croc_soc` macro) in Icarus; run it inside the template's nix-shell. `scripts/gls/tb_chip.v` is a plain
Verilog test bench that drives only the pins a board drives: `ref_clk_i`, `rst_ni`, the four JTAG pins and the UART RX.
It leaves `testmode_i`, `scan_si_i` and `scan_se_i` open, loads the 272-byte program through the debug module (JTAG,
system bus access), wakes the core and waits for `GLS OK` on the `uart_tx_o` pad. `scripts/gls/run_macro_gls.sh` and
`scripts/gls/tb_macro.v` are the same test with the macro alone (about 20 s per run).

Result with the AUS-106 macro in the chip of 14 Oct (template run `RUN_2026-10-14_23-22-13`, `testmode_i` pad open):
ID code 0x1c0c5db3 read through the pads, program loaded, `GLS OK` received on the pad at 912845 ns. The PD pin of the
`testmode_i` pad is read from the netlist (it is 1: the template ties it high) and the test bench pulls the open pad
down weakly when it is, because the vendor `in_c` model is a plain buffer that ignores PD and PU.

Icarus pitfalls found on the way (each one stopped the program at the UART without any error message):

- The cell library has no `timescale`, so Icarus uses 1 s units and rounds the 0.5 ns flop delay to 0. Both scripts
  prepend `` `timescale 1ns/1ps `` to the patched cells and primitives. Without it the SRAM model samples the address
  of the next cycle (the same race as with a too small flop delay in Verilator) and the core executes a wrong
  instruction stream.
- The primitives have no power-up value, so every unreset flop is `x` for ever. `INIT` (default 0) adds an
  `initial Q` to every sequential primitive, like a two-state simulator.
- The netlist headers hold one comment line of many thousand characters that the Icarus scanner cannot take; the
  scripts strip the lines starting with `//`.
- TDO must be sampled a few ns after the falling TCK edge (pad delay), and the chip netlist has no `DVDD`/`DVSS`
  ports (the power pins are inout nets inside).

## Scan shift

`sim/scripts/run_gls_scan.sh [work dir]` shifts a pseudo-random stream through the scan chain of the netlist
(`rtl/test/tb_scan_shift.sv`, testmode_i = scan_se_i = 1, both clocks with the waveforms of the DFT spec) and checks
that scan_so_o is the same stream delayed by exactly the number of scan cells (3964). The chain passes, also with
jtag_trst_ni driven low. With rst_ni driven low the chain is disturbed: rst_ni is a DFT reset signal that the tester
holds inactive during scan, and the 800 flops behind the reset generator (which passes rst_ni through in test mode)
are not gated by testmode_i. This is the zero-delay shift test: it proves chain order, enables and reset gating, not
hold timing (the scan-mode STA covers that).

## Gotchas

- `sim/sw/*/link.ld` and the committed `bin/*.hex` assume the old 16 KB SRAM (commit a1704ce shrank it to
  2 KB). Those images wrap around and overwrite the vector table, in RTL too. Rebuild for 2 KB, or load code
  through the QSPI boot trampoline.
- `rtl/test/tb_croc_soc.sv` has `` `define TRACE_WAVE `` hard-coded. Never build with `--trace`: it wrote tens of GB.
- Verilator needs g++ with `-fcoroutines` for `--timing`. The system g++ 8.5 on Rocky has none; set `GLS_CXX`.
- Run with `stdbuf -oL`, otherwise the output of a killed run is lost.
- Icarus cannot parse the SystemVerilog testbench.
