# fft_hwpe: AE-FFT accelerator

OBI subordinate (registers, 4 KB at `UserFftAddrBase`) and OBI manager (DMA) for the Croc user domain.
Interrupt: `interrupts_o[2]` of the user domain.  See `sim/fft/README.md` for the verification and the register map in `fft_hwpe.sv`.

| File | Function |
|---|---|
| `fft_hwpe.sv` | Top: registers, controller, core |
| `fft_hwpe_regs.sv` | OBI register file |
| `fft_hwpe_ctrl.sv` | DMA: reads 64 words, optional 65-word dump, error handling |
| `fft_hwpe_core.sv` | Load, FFT, post-processing sequencing and the local memory |
| `fft_pre.sv` | Offset, gain, window, time-domain energy term |
| `fft_butterfly.sv` | Radix-2 butterfly with rounding (from FFTodile) |
| `fft_post.sv` | Real-FFT post-processing for one bin |
| `fft_feat.sv` | Power, peak, band and total energy |
| `fft_cos_rom.sv`, `fft_trig.sv`, `fft_window.sv` | 33-entry cosine ROM, twiddle lookup, Hann window |

Licence: Apache-2.0.  `fft_butterfly.sv`, the register file and the DMA controller follow FFTodile
(ETH Zurich and University of Bologna).
