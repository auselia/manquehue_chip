# AE-FFT accelerator (fft_hwpe): RTL verification

RTL: `rtl/user_domain/fft/`.  Specification: `doc/spec_fft.tex` of the Auselia AFE project (not in this repository).

The accelerator takes 128 signed 16-bit samples (two per 32-bit word) from the system SRAM, applies offset, gain,
a Hann window, a 64-point complex FFT and real-FFT post-processing, and returns the peak bin, the band energy,
the total energy, the time-domain energy, and the flags BAND_OK and DECAY.  It is based on the iterative
radix-2 core of FFTodile (ETH Zurich and University of Bologna, Apache-2.0).

## Layout

| Path | Content |
|---|---|
| `model/aefft_model.py` | Bit-accurate golden model. The numeric contract is in its docstring. |
| `gen_vectors.py` | Makes the test vectors: synthetic cases and recorded AE blocks. |
| `vectors/` | Generated hex files (`in`, `cfg`, `exp_*`), `names.txt`, `vectors.json`. |
| `tb/tb_fft_hwpe_core.sv` | Core test: load stage, FFT output, every bin power, dump stream, result registers. |
| `tb/tb_fft_hwpe.sv` | Bus test: registers, DMA, interrupt, dump on and off, random grant, bus error. |
| `run_core.sh`, `run_bus.sh` | Build and run one test with Verilator. |
| `run_all.sh` | Full regression. |
| `../sw/aefft_test/` | System test: C program on the CVE2 core of the full SoC. |

## Run

```bash
export PATH=/path/to/oss-cad-suite/bin:$PATH      # Verilator 5
sim/fft/run_all.sh                                 # core test and bus test sweep
sim/sw/aefft_test/build.sh                         # needs riscv64-unknown-elf-gcc
BUILD_ONLY=1 sim/scripts/run_verilator.sh          # build the SoC model once
SKIP_BUILD=1 sim/scripts/run_verilator.sh sim/sw/aefft_test/bin/aefft_test.hex   # expect: AEFFT PASS
```

`gen_vectors.py --captures DIR` rebuilds the vectors.  The recorded blocks need the scope CSV files in DIR.
The committed vectors already contain them, so the CSV files are not needed to run the tests.

## What the tests compare

Every check is bit-exact against the golden model:
windowed samples after load, `Z[k]` after the FFT, `P[k]` of every bin, the 65-word dump, `PEAK_BIN`, `PEAK_POW`,
`BAND_ENERGY`, `TOTAL_ENERGY`, `TD_ENERGY`, `TD_PREV`, and the STATUS flags SAT, PREV_VALID, BAND_OK, DECAY.

Test blocks: 99 blocks from synthetic signals (zero, DC, impulse, full scale, one sine per bin, saturation,
random, burst with decay, threshold equality) and recorded AE data (3 blocks of each of 5 quiet records and
3 tone records, 7 events with a following block, a gain sweep).

## Specification changes made while building the RTL

- STATUS has an ERROR bit at [6] (as in FFTodile).  The spec had no error bit.
- `TD_PREV` reads the `TD_ENERGY` of the previous run.  `CTRL.CLR_PREV` clears PREV_VALID, `TD_ENERGY` and `TD_PREV`.
- The Hann window is `(32768 - cos) >> 1` from the 33-entry ROM, so no second table and no multiplier for it.
- Butterfly outputs and `P[k]` saturate and set SAT.  `Xr` and `Xi` are 18-bit inside; the dump saturates to 16 bit.
- Post-processing runs one bin per cycle with its own four multipliers and two squarers (the spec assumed two cycles
  per bin).  Sharing multipliers with the butterfly is a later area step.
