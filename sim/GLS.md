# Gate-level simulation of croc_soc

`sim/scripts/run_gls.sh <program.hex> [work dir]` simulates the final netlist (`outputs/latest/croc_soc.v`)
with Verilator, zero delay, using the repo testbench. It patches copies of the testbench, netlist and cell
models in the work directory; the repo is not touched. See the script header for the patches and why.

## What works

- Program: `sim/sw/gls_mini/build.sh` builds a 272-byte program that prints `GLS OK` on the UART and fits the
  2 KB SRAM. It needs `riscv64-unknown-elf-gcc` (on Rocky: build it on the Mac and copy `bin/gls_mini.hex`).
- RTL passes with this program. In the gate simulation the JTAG ID code, the SRAM load and the core wake-up
  match the RTL timestamps.
- After that the core diverges from the RTL (a taken jump right after a store is skipped). This is probably an
  artefact of zero-delay simulation of the clock tree, not a netlist error, but it is not proven. Unit delay on
  all gates runs Verilator out of memory, so it could not be checked that way. Formality is the better tool
  for equivalence.

## Gotchas

- `sim/sw/*/link.ld` and the committed `bin/*.hex` assume the old 16 KB SRAM (commit a1704ce shrank it to
  2 KB). Those images wrap around and overwrite the vector table, in RTL too. Rebuild for 2 KB, or load code
  through the QSPI boot trampoline.
- `rtl/test/tb_croc_soc.sv` has `` `define TRACE_WAVE `` hard-coded. Never build with `--trace`: it wrote tens of GB.
- Verilator needs g++ with `-fcoroutines` for `--timing`. The system g++ 8.5 on Rocky has none; set `GLS_CXX`.
- Run with `stdbuf -oL`, otherwise the output of a killed run is lost.
- Icarus cannot parse the SystemVerilog testbench.
