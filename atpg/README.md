# ATPG inputs for croc_soc (AUS-106 netlist). Jira: AUS-108

Status: inputs prepared, the ATPG tool (TestMAX ATPG Y-2026.03) is not installed on Rocky yet. The licenses exist
(Test-ATPG-P4/P5, Test-Compression-ATPG, Test-DFTC-TMAX, version 2026.03, expire 24 Jun 2027).

| File | What |
|---|---|
| `croc_soc.stil` | test protocol written by Fusion Compiler (`write_test_protocol`): clocks and waveforms, scan chain, constraints |
| `croc_soc_atpg.v` | final netlist without the VDD/VSS ports |
| `cells_atpg.v`, `primitives_atpg.v` | PDK simulation models of the standard cells (weak keeper removed) |
| `sram_blackbox.v` | port-only model of the SRAM macro: black box |
| `atpg.tcl` | ATPG script (draft, untested) |
| `export_stil.tcl`, `dft_spec.tcl`, `make_inputs.sh` | how the files were made |

Expected effects on coverage (known before running):
- the reset and set pins are held inactive in test (testmode_i gate, rst_ni held by the tester): the reset logic and the
  reset action are not testable;
- the four SRAM macros are black boxes: their outputs are unknown, so logic that only observes them loses coverage;
- rules C5, C8, C26 and S22 remain as warnings from dft_drc (104 in total).
