# Scan test of `croc_soc` on the wafer.space chip: tester procedure (AUS-108)

Scope: production-style stuck-at test of the digital logic of `croc_soc` through the scan chain, applied at the pins of
the `chip_top` pad ring. 573 patterns, 3,964 scan cells, 96.51 % stuck-at test coverage (TestMAX ATPG Y-2026.03-SP2,
netlist of the AUS-106 macro). The vectors are plain text files; nothing here needs a Synopsys tool to apply them.

## 1. Pins

The scan test uses 17 inputs and 20 outputs of the macro. At the chip they are these pads
(`src/chip_core.sv` of the template, slot 0p5x1):

| Macro port | Chip pad | Direction at the tester | During the scan test |
|---|---|---|---|
| `clk_i` | `clk_PAD` | drive | pulsed (see section 3) |
| `rst_ni` | `rst_n_PAD` | drive | 1; pulsed low in some capture cycles |
| `ref_clk_i` | `input_PAD[0]` | drive | per vector file |
| `testmode_i` | `input_PAD[1]` | drive | **1** for the whole test |
| `jtag_tck_i` | `input_PAD[2]` | drive | pulsed (see section 3) |
| `jtag_tms_i` | `input_PAD[3]` | drive | per vector file |
| `jtag_tdi_i` | `bidir_PAD[13]` | drive | per vector file |
| `jtag_trst_ni` | `bidir_PAD[14]` | drive | per vector file (0 in some capture cycles) |
| `uart_rx_i` | `bidir_PAD[15]` | drive | per vector file |
| `scan_si_i` | `bidir_PAD[16]` | drive | scan data in |
| `scan_se_i` | `bidir_PAD[17]` | drive | 1 while shifting, 0 in capture |
| `scan_so_o` | `bidir_PAD[18]` | compare | scan data out |
| `status_o` | `bidir_PAD[0]` | compare | capture cycles |
| `jtag_tdo_o` | `bidir_PAD[1]` | compare | capture cycles |
| `uart_tx_o` | `bidir_PAD[2]` | compare | capture cycles |
| `qspi_clk_o` | `bidir_PAD[3]` | compare | capture cycles |
| `qspi_csn_o[0..2]` | `bidir_PAD[4..6]` | compare | capture cycles |
| `qspi_sd_i[k]` / `qspi_sd_o[k]`, k = 0..3 | `bidir_PAD[7+k]` | see section 4 | |
| `gpio_i[k]` / `gpio_o[k]`, k = 0..1 | `bidir_PAD[11+k]` | see section 4 | |

Supply: 5.0 V on `VDD`/`DVDD` (the library corners are 4.5 / 5.0 / 5.5 V). Ground on `VSS`/`DVSS`.

## 2. Cycle and sequence

One vector is one cycle of 100 ns (10 MHz). A slower cycle works the same way; do not go below 100 ns without a new
timing check (the scan-shift STA of AUS-106 is signed off at 100 ns).

Sequence:

1. `test_setup`: all inputs 0, then `testmode_i` = 1 and `rst_ni` = 1, `scan_se_i` = 0, `clk_i` = `jtag_tck_i` = 0
   (two idle cycles, no pulses, no compare).
2. For pattern k = 0 .. 572:
   1. load/unload: one idle cycle with `scan_se_i` = 1, `testmode_i` = 1, `rst_ni` = 1, clocks 0; then 3,964 shift
      cycles. In shift cycle j: `scan_si_i` = `si.mem[k][j]`, `clk_i` and `jtag_tck_i` pulsed, and `scan_so_o` is
      compared with `so_exp.mem[k][j]` where `so_mask.mem[k][j]` = 1 (the unload of pattern k-1; pattern 0 has
      nothing to compare). All other inputs hold the value they had.
   2. capture: one cycle with the inputs of `pi.mem[k]` (`scan_se_i` = 0), pulses where `pi_pulse.mem[k]` = 1,
      outputs compared with `po_exp.mem[k]` where `po_mask.mem[k]` = 1.
3. Last: one load/unload (`si.mem[573]` is all 0) to unload pattern 572, compared with `so_exp.mem[573]`.

Total: 573 x 3,965 + 3,965 + 2 = 2,276,487 cycles = 0.23 s at 10 MHz.

## 3. Waveform inside the 100 ns cycle

| Time | Event |
|---|---|
| 0 ns | all inputs take their value for the cycle (pulsed inputs sit at their rest level) |
| 40 ns | outputs are compared |
| 50 - 70 ns | `clk_i` high if pulsed |
| 75 - 90 ns | `jtag_tck_i` high if pulsed; `rst_ni` low if pulsed |

Rest levels of pulsed inputs: `clk_i` 0, `jtag_tck_i` 0, `rst_ni` 1. In every shift cycle `clk_i` and `jtag_tck_i`
are both pulsed. The only pulsed inputs in capture cycles are `clk_i`, `jtag_tck_i` and `rst_ni`.

## 4. The six bidirectional functional pads

`qspi_sd[0..3]` and `gpio[0..1]` are inputs and outputs of the macro at the same time in the patterns; at the chip
they are one pad each, direction set by the macro (`qspi_sd_en_o`, `gpio_out_en_o`). In a capture cycle:

- if the expected enable (`qspi_sd_en_o[k]` or `gpio_out_en_o[k]` in `po_exp.mem`) is 0: drive the input value of
  `pi.mem` on the pad and do not compare the output `qspi_sd_o[k]` / `gpio_o[k]` (not visible at the pad);
- if it is 1: release the pad (high impedance) and compare the output.

In the shift cycles the chip state is arbitrary and the enables can be 1, so the tester releases these six pads during
every load/unload and drives them only in the capture cycle. The simulation holds the previous values during the
shifts; the scan flops do not take their data from these inputs while `scan_se_i` is 1, so the result does not depend
on it.

In the 573 patterns `qspi_sd_en_o[1..3]` is always 0, so those three pads are always driven by the tester;
`qspi_sd_en_o[0]`, `gpio_out_en_o[0]` and `gpio_out_en_o[1]` change from pattern to pattern. Outputs behind a
disabled pad are not observable at the chip; the tool run with those three outputs masked gives the same coverage
(96.52 %).

## 5. Pass criterion

Every compared bit equals the expected value. Any difference, or an output that is not a clean 0 or 1, fails the
die. A chip with a stuck `scan_so_o` fails in the first shift cycles: this is the chain test of pattern 0.

## 6. Files

| File | Content |
|---|---|
| `si.mem` | 574 lines of 3,964 bits: `scan_si_i` per load/unload, first bit is shifted first |
| `so_exp.mem`, `so_mask.mem` | 574 lines of 3,964 bits: expected `scan_so_o` and compare mask |
| `pi.mem`, `pi_pulse.mem` | 573 lines of 17 bits: inputs and pulsed inputs of the capture cycles; bit order `clk_i`, `rst_ni`, `ref_clk_i`, `testmode_i`, `jtag_tck_i`, `jtag_tdi_i`, `jtag_tms_i`, `jtag_trst_ni`, `uart_rx_i`, `qspi_sd_i[3:0]`, `gpio_i[1:0]`, `scan_si_i`, `scan_se_i` |
| `po_exp.mem`, `po_mask.mem` | 573 lines of 20 bits: expected outputs and compare mask; bit order `status_o`, `jtag_tdo_o`, `uart_tx_o`, `qspi_clk_o`, `qspi_sd_o[3:0]`, `qspi_sd_en_o[3:0]`, `qspi_csn_o[2:0]`, `gpio_o[1:0]`, `gpio_out_en_o[1:0]`, `scan_so_o` |
| `patterns_stuck.stil` | the same patterns as TestMAX ATPG wrote them |
| `faults_untested.txt` | the 4,888 faults that no pattern detects |
| `tb_atpg.v`, `sim_patterns.sh`, `stil_to_vectors.py` | the reference application of these files in a simulator |

## 7. What this test does not cover

- The SRAM macros: scan does not reach them. A March-style test program over JTAG is the plan; it does not exist yet.
- The pad ring itself (input thresholds, drive strength, bidir direction logic): the vectors exercise the pads only
  as wires.
- Faults the tool lists as untestable: 4,888 in `faults_untested.txt` (4,859 ATPG-untestable and 29 undetectable:
  logic behind the constrained pins, behind the SRAM outputs and behind the 232 clock-gate latches).
- Delay defects: stuck-at patterns do not check timing. There are no transition-delay patterns yet.

## 8. When a die fails: where is the defect?

The result of a test run is a list of mismatches, each with: pattern number, kind (`shift` = `scan_so_o` during the unload,
`capture` = an output in the capture cycle), shift cycle j and the output. `tb_atpg.v` prints them as `FAIL kind=... pat=...
j=... bit=... exp=... got=...`; a tester log with the same fields works the same way.

Order of checks:

1. **Is it the setup?** Run the pattern 0 chain test first (`si.mem` line 0 is a 0011 pattern). If `scan_so_o` is stuck or
   never changes, check `testmode_i` = 1, `scan_se_i` = 1, `rst_ni` = 1, both clocks reaching the die and the supply. Repeat
   at a slower cycle and on a known-good die. Only then suspect the chip.
2. **Chain broken?** Failures in every load/unload, thousands of different cells, nearly all read as the same value (always 0
   or always 1): the scan path is stuck. The failing cell names are not the defect, because the load was wrong as well.
   `diagnose.py` recognises the signature and says so; to find the position, run TestMAX Diagnosis with `-chain_failure`
   (step 5). Needs ten or more patterns.
3. **Isolated cells?** A few cells fail in some patterns, with both values: the defect is in the logic that feeds those cells
   (or in the cell itself). `diagnose.py` lists the cells by name, most frequent first; the common input cone of the top few
   is the suspect region.
4. **Output pins in capture?** `capture` failures name the output pin: the defect is in the logic of that output.
5. **TestMAX Diagnosis.** `diagnose.py --tmax fail.log` writes the failure file in the pattern-based format that
   `run_diagnosis` reads (`pattern_num output_port cell_position`):

       read_image / run_build_model + run_drc as in atpg.tcl
       set_patterns -external patterns_stuck.stil
       run_diagnosis fail.log

   It lists candidate faults with a match percentage and the cell or net; `run_diagnosis fail.log -chain_failure` for a
   broken chain (position counted from `scan_so_o`, 0 = the cell next to the pin). In the demonstration runs of the
   repository (10 patterns, injected defects) it found: the isolated D-input defect among 4 pins of the right cell, the
   stuck scan path at the right cell (2 candidates), and a scan input stuck at 0 among 732 candidate positions that
   include the right one. The defect type it prints (stuck-at-0 / stuck-at-1) was the opposite of the injected one in
   both chain cases; the position was right. Use more failing patterns to narrow a long candidate list.

`diagnose.py` and the fault-injection runs that prove it are in the repository (`make_faults.py`).
