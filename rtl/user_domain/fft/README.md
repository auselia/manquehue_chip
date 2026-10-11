# fft_hwpe: AE-FFT accelerator (minimum-area version)

OBI subordinate (registers, 4 KB at `UserFftAddrBase`) and OBI manager (SRAM access) for the Croc user domain.
Interrupt: `interrupts_o[2]` of the user domain.  Verification: `sim/fft/README.md`.  Register offsets: `fft_hwpe.sv`.

It transforms 128 real 16-bit samples (64 words) in place in the system SRAM, with no local data memory and one
serial 16 x 16 multiplier, and returns the peak bin, band energy, total energy, time-domain energy, BAND_OK and DECAY.
A run takes about 29 000 clock cycles (1.5 ms at 20 MHz), for one triggered block.

| File | Function |
|---|---|
| `fft_hwpe.sv` | Top: registers and core |
| `fft_hwpe_regs.sv` | OBI register file. SRC_ADDR keeps only the SRAM word index |
| `fft_hwpe_core.sv` | Sequencer, serial multiplier, bus master, features |
| `fft_trig.sv`, `fft_cos_rom.sv` | Twiddle and window values from one 33-entry cosine ROM |

The source buffer is overwritten: by the windowed samples, then by the spectrum Z[k] at word `SRC + bitreverse6(k)`.
Licence: Apache-2.0.  The sequencing and the register file follow FFTodile (ETH Zurich and University of Bologna).
