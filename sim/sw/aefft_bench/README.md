# AE-FFT benchmark: accelerator against software on Croc

One recorded AE block (`fw_event1.0`, 128 samples) is processed two ways in the full-SoC Verilator simulation.
Both give the registers of the golden model (peak bin 13, band 2 072, total 2 131, TD 27 499).

- `ONLY_HW` build: the CPU starts `fft_hwpe` and polls DONE.
- default build: the same algorithm in C on the CVE2 core. It matches the accelerator bit for bit.

Cycles come from `mcycle` at the 20 MHz system clock. The UART prints hex values.

| | Cycles | Time at 20 MHz |
|---|---|---|
| Accelerator (CYCLES register) | 29 145 | 1.46 ms |
| Accelerator (start to done, seen by the CPU) | 29 157 | 1.46 ms |
| Software, core as it is (no multiplier) | 236 539 | 11.83 ms |
| of which window pass / FFT / bins | 34 371 / 132 932 / 69 231 | |
| Software, core with a single-cycle multiplier (not built into Croc) | 64 640 | 3.23 ms |

## Run

```bash
cd sim/sw/aefft_bench
TAG=_sw DEFS= ./build.sh                 # software
TAG=_hw DEFS=-DONLY_HW ./build.sh        # accelerator
# with a multiplier, only for the comparison (the simulator must be built with RV32M enabled in rtl/core_wrap.sv):
MARCH=rv32imc_zicsr TAG=_sw_m DEFS= ./build.sh
SKIP_BUILD=1 ../../../scripts/sim/run_verilator.sh bin/aefft_bench_sw.hex
```

The program works in place on its own data, so each build runs once. Keys of the UART line: `T` total, `W` window pass,
`F` FFT, `B` bins, `R` CYCLES register, `S` 1 when the result matches. The last line is `P` or `F`.
