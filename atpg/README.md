# ATPG inputs for croc_soc (AUS-106 netlist). Jira: AUS-108

Status: first ATPG run done on 15 Oct 2026 (result at the end). TestMAX ATPG Y-2026.03-SP2 is installed on Rocky
(standalone `txs` package; the `tx` package is an overlay for Design Compiler and does not fit). The licenses
(Test-ATPG-P4/P5, Test-Compression-ATPG, Test-DFTC-TMAX, version 2026.03) expire 24 Jun 2027.

| File | What |
|---|---|
| `croc_soc.stil` | test protocol written by Fusion Compiler (`write_test_protocol`): clocks, waveforms, constraints, capture procedures (no scan chain definition) |
| `croc_soc_atpg.v` | final netlist without the VDD/VSS ports |
| `cells_atpg.v`, `primitives_atpg.v` | PDK simulation models of the standard cells (weak keeper removed) |
| `sram_blackbox.v` | port-only model of the SRAM macro: black box |
| `atpg.tcl` | ATPG script (runs; see the result below) |
| `fix_inputs.py` | makes the netlist and the protocol acceptable to the tool (see the result below) |
| `export_stil.tcl`, `dft_spec.tcl`, `make_inputs.sh` | how the files were made |

Expected effects on coverage (known before running):
- the reset and set pins are held inactive in test (testmode_i gate, rst_ni held by the tester): the reset logic and the
  reset action are not testable;
- the four SRAM macros are black boxes: their outputs are unknown, so logic that only observes them loses coverage;
- rules C5, C8, C26 and S22 remain as warnings from dft_drc (104 in total).

## Result of the first run (15 Oct 2026, TestMAX ATPG Y-2026.03-SP2, standalone `txs` package)

Run: `fix_inputs.py croc_soc_atpg.v croc_soc.stil <dir>`, then `tmax -shell -tcl atpg.tcl` in `<dir>`
(`SNPSLMD_LICENSE_FILE=27020@localhost`, tool in `/usr/synopsys/txs/Y-2026.03-SP2/bin`). The run takes 47 s, 40 s of
it checking out the licenses.

| Item | Value |
|---|---|
| Scan chain traced by the tool | `c1`, 3,964 cells, `scan_si_i` to `scan_so_o` (same as the shift simulation) |
| Clocks | `clk_i` 3,697 scan flops, `jtag_tck_i` 267, `rst_ni` as set/reset; 229 clock-gating cells found controllable |
| Faults (stuck-at, uncollapsed) | 141,612 |
| Detected | 136,620 (+ 54 possibly detected) |
| ATPG untestable (AU) | 4,859 |
| Undetectable (UD) | 29 |
| Not detected (ND) | 50 |
| **Test coverage** | **96.51 %** |
| Patterns | 573 basic-scan patterns, 2,276,485 test cycles (0.23 s at 100 ns per cycle) |

What was needed to get there (all done by `fix_inputs.py`, nothing was changed in the design):

1. The protocol that Fusion Compiler writes (`write_test_protocol`, "Minimal STIL") has the capture procedures only. It
   has no ScanStructures and no `load_unload`, so the tool saw 3,964 non-scan flops and reached 0.01 % coverage
   (141,576 faults untestable). With the chain declared the tool traces all 3,964 cells.
2. The netlist needed the 80,000-character header comment dropped, the `.VDD`/`.VSS` connections removed (the
   PDK models have no power pins) and the 1,628 `fillcap` cells removed.

Where the untested faults are: 4,888 in `faults_untested.txt` (4,859 AU + 29 UD). By block: core 1,783, UART 500,
SRAM interface 289, JTAG debug 193, timer 102, soc_ctrl 72, crossbar 70, CLINT 160, the rest on cells with generated
names. The tool's own analysis of the 4,119 faults of class AU: 3,286 are untestable because of constrained values
(`testmode_i` = 1, `scan_se_i` = 0 in capture, `rst_ni` held), 698 because of the blockage those values cause; 2,063
touch an unknown value (SRAM black boxes and tied-X nets) and 1,909 touch a transparent latch (the 232 clock-gate
latches). 91 faults have no explanation yet. The groups overlap, so they do not add up to 4,119.

Warnings that stay: S22 (the chain is clocked by `clk_i` and `jtag_tck_i`, expected), V14 (one missing state in the
protocol), C5/C8/C26 (the same ones `dft_drc` reports). Patterns written under C8 can fail in simulation: before
a tester uses them, they must be simulated on the netlist (serial and parallel), with the same flop delay as in
`sim/GLS.md`.

Not done yet: transition-delay patterns (at-speed), IDDQ, the fault list with the SRAM macros modelled instead of
black boxes, and the gate-level simulation of the written patterns (`patterns_stuck.stil`, 5 MB, not committed).

## The patterns applied to the gate-level netlist (15 Oct 2026)

`sim_patterns.sh <run dir> 9` converts `patterns_stuck.stil` into plain vector files (`stil_to_vectors.py`) and applies
them cycle by cycle to `croc_soc_atpg.v` in Icarus (`tb_atpg.v`: 100 ns cycle, outputs strobed at 40 ns, flop delay
0.5 ns as in `sim/GLS.md`). The SRAM stays the black box of the ATPG run. TestMAX's own testbench (`stil2verilog`) does
not run in Icarus (it uses `$save`/`$restart`), so this player replaces it; it applies the same protocol.

| Item | Value |
|---|---|
| Patterns applied | 573 of 573 (9 independent chunks of 64, each from a loaded chain) |
| Cycles | 2,276,487 |
| Output values compared | 2,281,758 |
| Mismatches | **0** |
| Wall time | 2 h 22 min on 9 cores (about 31 cycles/s per process) |

The C8 warning of the ATPG run (patterns may fail in simulation) did not show up as a failing pattern. Vectors and the
procedure for a tester: `TEST_PROCEDURE.md`. The vector files are not in git (7 MB, regenerated by
`stil_to_vectors.py`); the package of this run is `croc_soc_atpg_vectors_20261015.tar.gz` (Rocky `~/Documents/croc_run_archive/`).
