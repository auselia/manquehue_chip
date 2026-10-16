# verify/: sign-off and regression of a croc_soc run

Everything that checks a finished Fusion Compiler run lives here and is started with `make`. Nothing writes to `/tmp`:
each step writes into the run folder, `outputs/<run>/verify/<step>/`, and a one-line-per-key `summary.txt`.
`make report` collects the summaries into `results/<commit>.md`.

| Target | What it runs | Time (Rocky, 9 cores) | Needs |
|---|---|---|---|
| `make signoff` | KLayout DRC and LVS, PrimeTime functional STA at 3 corners, Formality (RTL vs gate with the SVF chain) | about 1 h | `make all pt_export` of this checkout (Formality reads the run's `logs/` and `svf/`, copied there at the end of `make finish`) |
| `make scan-sta` | scan-shift STA (`scan_se_i` = 1, `testmode_i` = 1), 3 corners, hold and setup on the 3,821 scan inputs | 5 min | `outputs/<run>/croc_soc_scan.sdc` and SPEF |
| `make gls` | Verilator boot of the netlist (`GLS OK`), scan shift (lag = number of cells), Icarus macro boot over JTAG | 15 min | the template's nix-shell (verilator, iverilog) |
| `make dft` | scan chain trace, ATPG, replay of the patterns on the netlist, SRAM March test with injected faults | 10 min with `NPAT=20`, 3 h for all patterns | TestMAX ATPG (`txs`), iverilog |
| `make chip` | wafer.space chip flow with the pad ring, precheck, chip-level GLS through the pads | 1.5 h | template with the `testmode_i` pull-down, precheck repository |
| `make check` | scan-sta, gls, dft, chip, report | 4 to 5 h | all of the above |

`RUN` selects the run: a folder name under `outputs/` or an absolute path (default `outputs/latest`).
`NPAT`, `JOBS` and `COB` are described in `verify.mk`. Tool paths are in `env.sh`; override them in `verify/local.env`.

## Layout

```
verify/
  env.sh                 paths and helpers, one place
  verify.mk              the make targets
  report.py              results/<commit>.md
  sta/                   scan_sta.sh, signoff_summary.sh
  gls/                   run_gls_all.sh, run_macro_gls.sh, run_chip_gls.sh, run_sram_march.sh, testbenches, prog/ (2 KB test program)
  dft/                   run_dft.sh, ATPG inputs and script, pattern replay, diagnosis, TEST_PROCEDURE.md, README.md
  chip/                  run_chip_flow.sh (chip flow, precheck, chip-level GLS)
```

Pass criteria are in each script (`status: PASS` or `FAIL` in the summary). A step that cannot run (missing tool,
missing input) is `FAIL` with the reason, never silently skipped.

## What changes when the design changes

Any change to the netlist invalidates scan patterns, GLS and precheck. `make check` after every merge: `dft` regenerates
the patterns itself. The committed protocol `dft/croc_soc.stil` is a fallback for checkouts without `work/design.dlib`;
it is valid while the scan configuration (`scripts/common/dft_scan.tcl`) is unchanged.
