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
