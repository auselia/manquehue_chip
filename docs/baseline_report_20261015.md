# Report card, commit b40ee1e

Run: `/home/navillegas/Documents/manquehue_chip_wt/infra/outputs/croc_soc_20261010_173919`

| Step | Status | Date |
|---|---|---|
| signoff | PASS | 2026-10-15T17:59:22-03:00 |
| scan_sta | PASS | 2026-10-15T17:59:22-03:00 |
| gls | PASS | 2026-10-15T18:00:08-03:00 |
| dft | PASS | 2026-10-15T18:15:28-03:00 |
| chip | PASS | 2026-10-15T20:41:28-03:00 |

**ALL PASS**

### signoff

- date: 2026-10-15T17:59:22-03:00
- commit: b40ee1e
- setup_wns_ns: slow=3.31 typical=26.60 fast=36.24
- hold_wns_ns: slow=0.85 typical=0.33 fast=0.10
- lec_failing_points: 0
- lvs_errors: 0
- status: PASS

### scan_sta

- date: 2026-10-15T17:59:22-03:00
- commit: b40ee1e
- hold_violators: 0
- setup_violators: 0
- corners_timed: 3
- hold_worst_slack_ns(slow typical fast): 1.024051 0.363623 0.075420
- status: PASS

### gls

- date: 2026-10-15T18:00:08-03:00
- commit: b40ee1e
- verilator_boot: @    914450ns | [UART] GLS OK
- scan_shift: ALL PASS
- icarus_macro_boot: 912845 ns  [TB] PASS: GLS OK received on the uart_tx pad
- status: PASS

### dft

- date: 2026-10-15T18:15:28-03:00
- commit: b40ee1e
- protocol: committed baseline (no work/design.dlib in this checkout)
- scan_cells: 3964
- stuck_at_coverage_percent: 96.51
- patterns: 573
- replay: 573 of 573 patterns, chunks passed: 9 of 9, mismatches: 0
- march_good: 43333680 ns  MARCH PASS: 5120 accesses, 0 mismatches
- march_injected_faults_detected: 4 of 4
- status: PASS

### chip

- date: 2026-10-15T20:41:28-03:00
- commit: b40ee1e
- template_commit: 3d54a31+local changes
- chip_gds: /home/navillegas/Documents/manquehue_chip_wt/infra/outputs/croc_soc_20261010_173919/verify/chip/views/gds/chip_top.gds (107923272 bytes)
- chip_netlist: /home/navillegas/Documents/manquehue_chip_wt/infra/outputs/croc_soc_20261010_173919/verify/chip/views/pnl/chip_top.pnl.v
- precheck: Precheck successfully completed (5 Magic DRC errors) with --cob
- chip_gls: 912845 ns  [TB] PASS: GLS OK received on the uart_tx pad
- status: PASS
