# AE-FFT accelerator (fft_hwpe): RTL verification

RTL: `rtl/user_domain/fft/`.  Specification: `doc/spec_fft.tex` of the Auselia AFE project (not in this repository).

The accelerator transforms 128 signed 16-bit samples (two per 32-bit word) in place in the system SRAM:
offset, gain, Hann window, 64-point complex FFT (radix-2 DIF) and real-FFT post-processing.  It returns the peak bin,
the band energy, the total energy, the time-domain energy, and the flags BAND_OK and DECAY.
It is meant for one triggered block, so it is built for minimum area: no local data memory and one serial multiplier.
A run takes about 29 000 clock cycles.  It is based on FFTodile (ETH Zurich and University of Bologna, Apache-2.0).

## Layout

| Path | Content |
|---|---|
| `model/aefft_model.py` | Bit-accurate golden model. The numeric contract is in its docstring. |
| `gen_vectors.py` | Makes the test vectors: synthetic cases and recorded AE blocks. |
| `vectors/` | Generated hex files (`in`, `cfg`, `exp_*`), `names.txt`, `vectors.json`. |
| `tb/tb_fft_hwpe.sv` | Test on the bus interfaces: registers, SRAM access, interrupt, random grant, bus error. |
| `run_bus.sh` | Build and run it with Verilator (`run_bus.sh LATENCY RANDOM_GNT`). |
| `run_all.sh` | Full regression. |
| `../sw/aefft_test/` | System test: C program on the CVE2 core of the full SoC. |

## Run

```bash
export PATH=/path/to/oss-cad-suite/bin:$PATH      # Verilator 5
sim/fft/run_all.sh                                 # bus test sweep, 6 timing settings
sim/sw/aefft_test/build.sh                         # needs riscv64-unknown-elf-gcc
BUILD_ONLY=1 sim/scripts/run_verilator.sh          # build the SoC model once
SKIP_BUILD=1 sim/scripts/run_verilator.sh sim/sw/aefft_test/bin/aefft_test.hex   # expect: AEFFT PASS
```

`gen_vectors.py --captures DIR` rebuilds the vectors.  The recorded blocks need the scope CSV files in DIR.
The committed vectors already contain them, so the CSV files are not needed to run the tests.

## What the tests compare

Every check is bit-exact against the golden model:
the windowed buffer after the first pass, the spectrum `Z[k]` left in the buffer, the clipped `X[k]` and the power
`P[k]` of every bin, `PEAK_BIN`, `PEAK_POW`, `BAND_ENERGY`, `TOTAL_ENERGY`, `TD_ENERGY`, `TD_PREV`, and the STATUS
flags SAT, PREV_VALID, BAND_OK, DECAY.

Test blocks: 101 blocks from synthetic signals (zero, DC, impulse, full scale, one sine per bin, saturation,
random, burst with decay, threshold equality) and recorded AE data (3 blocks of each of 5 quiet records and
3 tone records, 7 events with a following block, a gain sweep).  The injected bus error is checked too.

## History

The first version (commit c98da9b) had a 2048-flop local memory and 12 parallel multipliers: 1.39 mm2 in GF180.
This version keeps the data in the system SRAM and shares one serial multiplier: see `synth/REPORT.md`
in the AFE project for the numbers.

## Specification changes made while building the RTL

- STATUS has an ERROR bit at [6] (as in FFTodile).  The spec had no error bit.
- `TD_PREV` reads the `TD_ENERGY` of the previous run.  `CTRL.CLR_PREV` clears PREV_VALID, `TD_ENERGY` and `TD_PREV`.
- There is no dump: `DST_ADDR` is not implemented (reads 0).  The spectrum stays in the source buffer.
- The source buffer is overwritten.  `SRC_ADDR` holds only the word index inside the SRAM.
- FFT is radix-2 DIF in place, output in bit-reversed order (the first version was DIT with bit-reversed load).
- The Hann window is `(32768 - cos) >> 1` from the 33-entry ROM.
- Every clip sets SAT.  The post-processing power uses X clipped to 16 bit.
- CONFIG VERSION is 2.  `CYCLES` is a 16-bit saturating counter.
- A run takes about 29 000 cycles instead of 411.  The requirement of back-to-back blocks was dropped,
  because the window comparator triggers the analysis.
