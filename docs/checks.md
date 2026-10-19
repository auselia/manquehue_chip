# Checks of a run

Everything that checks a finished Fusion Compiler run is started with `make` and writes into the run folder:
`outputs/<run>/checks/<step>/summary.txt`, and `make report` collects the summaries into `outputs/<run>/report.md`.
Nothing writes to `/tmp`.

| Target | What it runs | Time (Rocky, 9 cores) | Needs |
|---|---|---|---|
| `make signoff` | KLayout DRC and LVS, PrimeTime functional STA at 3 corners, Formality (RTL against gates with the SVF chain) | about 1 h | a run made with `make all` (Formality reads the run's `logs/` and `svf/`) |
| `make scan-sta` | scan-shift STA (`scan_se_i` = 1, `testmode_i` = 1), 3 corners, hold and setup on the 3,821 scan inputs | 5 min | `croc_soc_scan.sdc` and the SPEF of the run |
| `make gls` | Verilator boot of the netlist (`GLS OK`), scan shift, Icarus macro boot over JTAG | 15 min | the template's nix-shell (verilator, iverilog) |
| `make dft` | scan chain trace, ATPG, replay of the patterns on the netlist, SRAM March test with injected faults | 10 min with `NPAT=20`, 3 h for all patterns | TestMAX ATPG (`txs`), iverilog |
| `make chip` | wafer.space chip flow with the pad ring, precheck, chip-level GLS through the pads | 1.5 h | template with the `testmode_i` pull-down, precheck repository |
| `make check` | scan-sta, gls, dft, chip, report | 4 to 5 h | all of the above |

`RUN` selects the run (a folder name under `outputs/` or an absolute path, default `outputs/latest`). `NPAT`, `JOBS` and
`COB` are described in the Makefile. Tool paths are in `scripts/utils/env.sh`, override them in `scripts/utils/local.env`.

## Where things are

Folders under `scripts/` are named after what they do, not after the tool.

| What | Where |
|---|---|
| flow steps (Fusion Compiler) and their Tcl helpers | `scripts/01..06_*.tcl`, `scripts/common/` (sign-off SDC and SPEF: `common/export_signoff.tcl`, called by 06) |
| timing sign-off: PrimeTime STA, scan-shift STA, timing models (ETM), sign-off summary | `scripts/signoff/sta/` |
| power analysis | `scripts/signoff/power/` |
| equivalence check (Formality) | `scripts/signoff/lec/` |
| physical verification: metal fill and DRC/LVS runsets (IC Validator) | `scripts/signoff/pv/` |
| IR drop (RedHawk-SC) | `scripts/signoff/irdrop/` |
| scan test: ATPG, pattern replay, diagnosis, March test driver | `scripts/dft/` (documentation: `docs/dft_atpg.md`, tester procedure: `docs/TEST_PROCEDURE.md`) |
| simulation drivers: Verilator, VCS, gate-level, chip-level | `scripts/sim/` |
| chip flow and precheck | `scripts/chip/` |
| FPGA build | `scripts/fpga/` |
| report card, archive of logs and reports, tool paths | `scripts/utils/` |
| gate-level testbenches | `sim/tb/` |
| firmware, including the 2 KB test program (prebuilt image, no toolchain needed on Rocky) | `sim/sw/`, `sim/sw/gls_mini/gls_mini.hex` |
| report card of the baseline run | `docs/baseline_report_20261015.md` |

A step that cannot run (missing tool or input) is `FAIL` with the reason, never silently skipped.

## Accepted DRC results

The sign-off DRC (`make drc`, deck `gf180_drc_lvs`, metal stack C) has one accepted rule. All other rules must be clean.

| Rule | Where | Why it is accepted | Evidence |
|---|---|---|---|
| NW.2b_5V | 3 markers inside each of the 4 `gf180mcu_fd_ip_sram__sram512x8m8wm1` macros, at the same place in each | It is in the foundry SRAM layout itself. The flow does not change the macro. The deck of the wafer.space precheck (`.ciel` gf180mcuD) has no violation there | The bare SRAM GDS from `~/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram/gds` alone gives NW.2b_5V and nothing else (18 Oct). Present in every sign-off since 3 Oct |

The checks for the rules that the flow can make (DF.6, DF.13, DF.14, CO.6a and the routing rules) are in `scripts/06_finish.tcl` and `scripts/common/drc_eco.tcl`.

## What changes when the design changes

Any change to the netlist invalidates the scan patterns, the gate-level simulation and the precheck. Run `make check` after
every merge: `make dft` regenerates the patterns. The committed protocol `scripts/dft/croc_soc.stil` is a fallback for a
checkout without `work/design.dlib`, valid while the scan configuration (`scripts/common/dft_scan.tcl`) is unchanged.
