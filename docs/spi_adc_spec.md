# SPI block for the ADC and the radio: specification v0.2 (AUS-16)

Status: draft v0.2 for review, 15 Oct 2026 (v0.1 plus the datasheet and the test board data). Nothing in this document is in RTL yet. Inputs: `Auselia_AFE_v1/doc/SPI_design_handoff.md`,
the branch `wip/obi-spi-ads7057-bringup`, the user domain of `rtl/user_domain.sv`.

## 1. Goal and decisions

The Croc SoC talks to two parts. The **ADS7057** ADC (14 bit, SPI, AE sensor through the AFE board) and the **SX1276** radio
(RFM9x module, LoRa). The OpenTitan `spi_host` on the WIP branch is replaced.

| Decision | Reason |
|---|---|
| OBI native, no TL-UL bridge | The bridge cannot do byte writes, one access at a time, extra area and integrity logic |
| Two separate blocks on one OBI slave: a small SPI master for the radio and an ADC reader | The ADC needs about 900 kS/s with no CPU in the loop, the radio needs 1 to 10 MHz and software control |
| Dedicated pads, no pad sharing | The branch shares UART, GPIO and status pads through a pinmux. A transfer silences the UART |
| Small FIFOs (8 bytes) for the radio, none for the ADC | The OpenTitan FIFOs (72 + 64 words) are about 4,300 flops, more than the 3,964 flops of the whole SoC |
| ADC samples go straight to SRAM buffers through the user manager port | No CPU load, matches the FFT input format |
| No interrupt controller of its own | Two of the four user interrupt lines |

## 2. Block diagram

```
                  OBI subordinate (0x2200_0000, 4 KB)            user manager port (shared with the FFT)
                         |                                                  ^
                  +------+-------+                                          |
                  |  obi_spi_regs|                                    +-----+------+
                  +--+--------+--+                                    | obi write  |
                     |        |                                       | of 32-bit  |
         RF block (0x000)   ADC block (0x100)------------ samples ----->  words     |
          |                    |                                       +------------+
     +----+-----+         +----+-----+
     | rf_spi   |         | adc_rdr  |
     | master   |         |          |
     +--+-+-+-+-+         +--+-+-+---+
        | | | |               | | |
     SCLK MOSI MISO CSN    SCLK CSN SDO     (+ DIO0, RSTN, TRIG)
```

## 3. Placement

### Address map

| Window | Base | Size | Block |
|---|---|---|---|
| SPI | `0x2200_0000` | 4 KB | this block |
| FFT | `0x2200_1000` | 4 KB | `fft_hwpe` (the old pinmux register at that address disappears) |
| rest of the user design window | `0x2200_2000` to `0x3000_0000` | | `UserDesign`, error subordinate |

`user_pkg` gets two new indices (`UserSpi`, `UserFft`) and two new rules that do not overlap the QSPI window or
`UserDesign`, which moves to start at `0x2200_2000`.

### Interrupts

`interrupts_o[0]` = radio and SPI master, `interrupts_o[1]` = ADC reader, `[2]` = FFT, `[3]` reserved. Level
interrupts, cleared at the source.

### Manager port

The ADC reader and the FFT both write the SRAM. `user_mgr_obi_req_o` is tied to 0 today. Add an `obi_mux` (two managers) in
`user_domain`, ADC reader at port 0, FFT at port 1. The crossbar already has a user manager input.

### Pads

Thirteen new signals. The 0p5x1 slot has 44 bidirectional pads and 19 are used, so there is room (32 of 44).

| Pad (template `bidir[]`) | Signal | Direction | Note |
|---|---|---|---|
| 19 | `adc_sclk_o` | out | forwarded system clock, see section 6 |
| 20 | `adc_csn_o` | out | |
| 21 | `adc_sdo_i` | in | ADC data out |
| 22 | `adc_wake_n_i` | in | WAKE_N of the AFE board: latched window comparator, active low (the trigger) |
| 23 | `adc_big_n_i` | in | BIG_N of the AFE board: large event flag, optional |
| 24 | `adc_wake_clr_o` | out | clears the WAKE_N latch |
| 25 | `adc_cap_en_o` | out | CAP_EN of the AFE board: switches the capture chain supply, optional |
| 26 | `rf_sclk_o` | out | |
| 27 | `rf_mosi_o` | out | |
| 28 | `rf_miso_i` | in | |
| 29 | `rf_csn_o` | out | |
| 30 | `rf_dio0_i` | in | radio done or RX interrupt, optional |
| 31 | `rf_rstn_o` | out | radio reset |

Template changes: `src/chip_core.sv` (mapping, `bidir_oe` for the outputs, spare pads pull-down), the two slot yaml files
(pad lists), and a new chip-level pad table in `TEST_PROCEDURE.md`. The macro `croc_soc` gets thirteen new ports.

## 4. Radio SPI master (`rf_spi`, offsets 0x000 to 0x0FF)

Plain SPI master for the SX1276: mode 0 required (mode 1 to 3 supported), MSB first, byte oriented, full duplex.

### Registers

| Offset | Name | Access | Fields |
|---|---|---|---|
| 0x000 | RF_CTRL | RW | [0] EN, [1] SW_RST (self-clearing, flushes both FIFOs), [2] CPOL, [3] CPHA, [15:8] CLKDIV, [19:16] CS_SETUP (SCLK half periods, CS low before the first edge and after the last) |
| 0x004 | RF_STATUS | RO | [0] BUSY, [1] TX_EMPTY, [2] TX_FULL, [3] RX_EMPTY, [4] RX_FULL, [15:8] TX_LEVEL, [23:16] RX_LEVEL |
| 0x008 | RF_CMD | WO | [11:0] NBYTES (1 to 4095), [12] KEEP_CS (leave CS low after the transfer). The write starts the transfer: CS falls, NBYTES bytes are shifted, CS rises unless KEEP_CS |
| 0x00C | RF_DATA | RW | write: push one byte to TX (byte of the lowest enabled lane). read: pop one byte from RX, bits [7:0], upper bits 0 |
| 0x010 | RF_IRQ_EN | RW | [0] DONE, [1] TX_EMPTY, [2] RX_AVAIL, [3] ERROR, [4] DIO0 |
| 0x014 | RF_IRQ_STATUS | R/W1C | [0] DONE (sticky), [1] TX_EMPTY (level), [2] RX_AVAIL (level), [3] ERROR (sticky: TX overflow, RX overrun, RX underflow), [4] DIO0 rising edge (sticky) |
| 0x018 | RF_PINS | RW | [0] RSTN output level (reset value 0 = radio in reset), [8] DIO0 input level (RO) |
| 0x01C | RF_ERR | R/W1C | [0] TX_OVERFLOW, [1] RX_OVERRUN, [2] RX_UNDERFLOW |

SCLK = f_clk / (2 x (CLKDIV + 1)). At 18.18 MHz CLKDIV 24 gives 364 kHz (radio bring-up), CLKDIV 0 gives 9.1 MHz.

### Behaviour

- Software pushes the TX bytes, then writes RF_CMD. Every shifted byte puts one byte into the RX FIFO.
- A transfer longer than the FIFO (8 bytes) needs refilling during the transfer: the master stalls SCLK (CS stays low) while TX is
  empty, and holds on a full RX FIFO. No data is lost, the transfer takes longer. This also covers the 256-byte radio FIFO.
- Writing RF_DATA with a full TX FIFO drops the byte and sets TX_OVERFLOW. Reading an empty RX FIFO returns the last value
  and sets RX_UNDERFLOW. Neither gives a bus error.
- Byte, halfword and word accesses to every register are accepted. For RF_DATA the byte comes from the lowest lane with its
  byte enable set. This fixes problems 1 and 2 of the WIP branch.
- All outputs idle at their inactive level (CS high, SCLK at CPOL, MOSI 0) when EN is 0.

## 5. ADC reader (`adc_rdr`, offsets 0x100 to 0x1FF)

Reads the ADS7057 with no CPU in the loop and writes the samples into two SRAM buffers.

### Frame (datasheet SBAS821, section 8.4 and figures 1, 37, 38, 39)

SCLK idles **high**. A frame starts with CS falling and ends with CS rising. A leading 0 is on SDO from the CS falling edge. The
MSB (D13) is launched on the first rising edge after the first falling edge, every following bit on the following rising edges, then zeros
after D0. The host samples on the falling edges: falling edge 1 reads the leading 0, falling edges 2 to 15 read D13 to D0.
The conversion needs 18 falling edges in the frame, then at least tACQ = 95 ns must pass before the next CS falling edge. With fewer
than 18 falling edges the result of the next frame is invalid.

| Item | Datasheet value | Source |
|---|---|---|
| tCLK, SCLK high and low | 16.66 ns min (60 MHz), 45 to 55 % of the period | 6.6 |
| CS falling to first SCLK falling edge | 7 ns min | 6.6 |
| SCLK rising edge to CS rising edge | 8 ns min | 6.6 |
| CS high time | 15 ns min | 6.6 |
| tACQ (last conversion clock to next CS fall) | 95 ns min | 6.5 |
| SDO valid after CS fall | 6.5 ns max | 6.7 |
| SDO valid after SCLK rising edge | 10 ns max, holds 2.5 ns min | 6.7 |
| Conversion | 18 clocks, 14 data bits | 8.4.2 |

The result of a frame is the sample taken at the previous CS fall. The reader therefore:

- sends one calibration frame of 24 clocks at enable (offset calibration, zeros on SDO), and one more frame whose result is
  not valid (the sample of the calibration frame does not exist), so the first valid result is in the third frame,
- sends a 64-clock frame on request (CAL bit) to recalibrate during operation, the first 18 bits are a normal result,
- stores the 14-bit two's complement code sign-extended to 16 bit (full scale +-AVDD, 1 LSB = 0.4 mV at 3.3 V).

The system clock period at the 18.18 MHz sign-off clock is 55 ns. A frame is 18 clocks, CS rises one clock after the 18th falling
edge and the next CS fall is at least two clocks after it (110 ns, tACQ met with 15 ns to spare). At 20 MHz the margin is 5 ns.

| IDLE (clocks between the 18th falling edge and the next CS fall) | Clocks per sample | Rate at 18.18 MHz (55 ns) | Rate at 20 MHz |
|---|---|---|---|
| 2 (minimum) | 20 | 909 kS/s | 1.00 MS/s |
| 3 (default) | 21 | 866 kS/s | 952 kS/s |
| 4 | 22 | 826 kS/s | 909 kS/s |

The FFT block wants at least 800 kS/s, the events need more than 550 kS/s (peaks at 233 to 275 kHz).

### Registers

| Offset | Name | Access | Fields |
|---|---|---|---|
| 0x100 | ADC_CTRL | RW | [0] EN, [1] RUN (1 = start, 0 = stop after the current frame), [2] TRIGGERED (capture one buffer after a trigger instead of free running), [3] SW_TRIG (write 1, self-clearing, same effect as WAKE_N going low), [4] CAL (send a 64-clock frame, self-clearing), [5] SW_RST (self-clearing), [11:8] IDLE (clocks, min 2, default 3), [12] SDO_NEG (1 = sample SDO on the falling edge of `clk_i`, for a slow board, off by default), [14] TRIG_ACTIVE_LOW (default 1: the AFE signal nWAKE is active low), [15] SCLK_HALF (1 = SCLK is clk/2, fallback) |
| 0x104 | ADC_STATUS | R/W1C | [0] RUNNING, [1] BUF0_FULL, [2] BUF1_FULL, [3] OVERRUN (a buffer was still full when it had to be written), [4] BUS_ERROR (an OBI write got an error response), [5] DONE (triggered capture finished), [8] ACTIVE_BUF (RO, buffer being written) |
| 0x108 | ADC_BUF0 | RW | byte address of buffer 0 (word aligned, inside the SRAM) |
| 0x10C | ADC_BUF1 | RW | byte address of buffer 1 |
| 0x110 | ADC_NSAMP | RW | samples per buffer, even, 2 to 1024 (default 128) |
| 0x114 | ADC_IRQ_EN | RW | [0] BUF_FULL, [1] OVERRUN, [2] DONE, [3] WAKE (WAKE_N went low) |
| 0x118 | ADC_LAST | RO | most recent sample, sign-extended to 32 bit |
| 0x11C | ADC_COUNT | RO | samples stored since RUN (saturating) |
| 0x120 | ADC_PINS | RW | [0] WAKE_CLR output level (0 = latch cleared, set 1 to arm), [1] CAP_EN output level (reset 1), [8] WAKE_N input level (RO), [9] BIG_N input level (RO) |

### Data format

Two samples per 32-bit word, first sample in bits [15:0], second in bits [31:16]. This is the packing the FFT expects
(`z[m] = x[2m] + j x[2m+1]`). A buffer of 128 samples is 256 bytes. Two buffers use 512 bytes of the 2 KB SRAM.

### Behaviour

- Free running: fill buffer 0, set BUF0_FULL (interrupt if enabled), continue into buffer 1, then back to buffer 0. Software
  clears the full flag after it has used the buffer. If the reader needs a buffer that is still marked full it sets OVERRUN
  and drops that buffer's samples (the other buffer keeps its data).
- Triggered: the reader keeps running one buffer ahead and stops after the buffer that is being written when the
  trigger (pad `adc_trig_i` rising edge, or SW_TRIG) arrives completes, sets DONE. This gives samples from before and after
  the event. Exact pre-trigger length is one buffer at most (open item 3).
- The reader writes one 32-bit word per two samples with an OBI write of byte enable 1111. It holds two words in a staging
  register, so a manager stall of up to about 80 clocks (two words at 866 kS/s) loses nothing. A longer stall sets OVERRUN.
- The ADC inputs (`adc_sdo_i`, `adc_wake_n_i`, `adc_big_n_i`) are double-synchronised where they are not sampled directly. SDO is
  captured by a rising-edge flop of the system clock, which is exactly the SCLK falling edge, half a period after the launch. The path
  from the port is the critical one: SCLK launch (clock falling edge) + 10 ns (ADC) + pad, translator and trace must fit in half a
  period plus the clock latency difference. The flow experiment (`sim/experiments/fwd_clock`) gives +5.3 ns of slack in the
  slow corner at 55 ns with 19 ns off-chip. A slower board is covered by SDO_NEG (capture on the falling edge, 27.5 ns more setup
  margin, about 8 ns of hold margin).

## 6. Clock, reset, test and flow

### SCLK of the ADC

At 18 MHz the half-rate clock (`SCLK_HALF`) gives only about 480 kS/s (9.1 MHz SCLK, 19 clocks per sample), below the event
requirement. So the default is the system clock forwarded to the pad through a latch-based clock gate (`tc_clk_gating`, the ICG cell
the flow already uses) and an inverter, so that SCLK idles high as the datasheet requires and its falling edge is the rising edge of
`clk_i`. The enable comes from a flop of the system clock. SCLK high time and low time are one half clock period (the datasheet
allows 45 to 55 %, so the duty cycle of the clock at the port must stay within 5 %).

Consequences (checked in the flow experiment of section 8, step 2, results in `sim/experiments/fwd_clock/README.md`):

- The gate output feeds a pad, not flops. CTS treats the port as a clock sink. The SDC needs `create_generated_clock` on
  `adc_sclk_o`, output delays for CS relative to it (CS must fall 7 ns before the first SCLK falling edge and rise 8 ns after the
  last rising edge, both met by one clock of margin) and an input delay for `adc_sdo_i`.
- In scan mode the gate is forced by `testmode_i` so the pad is quiet and the chain is not affected.
- No negative-edge flops anywhere in the block. Scan, lock-up latches and the existing DFT flow stay as they are.
- Fallback if forwarding does not close: `SCLK_HALF`, about 480 kS/s at 18.18 MHz.

### Reset, test, area

- One clock domain, `clk_i`, asynchronous reset `rst_ni` as the rest of the SoC, gated by `testmode_i` in the same way (AutoFix).
- Every flop is a normal scan flop. The block adds roughly 250 flops (registers about 120, FIFOs 128, counters about 60). My estimate.
- The RF master and the ADC reader do not share state. ADC_CTRL.EN = 0 and RF_CTRL.EN = 0 make the pads quiet.

## 7. Verification plan (AUS-17)

Behavioural models (simulation only) are in `sim/models/`: `ads7057_model.v`, `sx1276_model.v`, self-test `tb_models.v`
(passes). Bus testbench: OBI manager task from `croc_vip`, same style as `tb_fft_hwpe`.

| Test | What it proves |
|---|---|
| RF register reset values, byte, halfword, word access to every register | problem 1 and 2 of the WIP branch are gone |
| RF transfer of 1, 2, 8, 9, 300 bytes, modes 0 and 3, CLKDIV 0 and 24, against `sx1276_model` | stall and refill, CS timing, data integrity |
| RegVersion read (0x42 returns 0x12), FIFO write 3 bytes and TX mode, DIO0 interrupt | bring-up sequence |
| TX overflow, RX overrun, RX underflow flags, SW_RST during a transfer | error handling |
| ADC reader against `ads7057_model`: first frame discarded, calibration frame, 128-sample buffers, ping-pong, sign extension, packing | data path |
| ADC at IDLE 2, 3, 4 and with SDO_NEG 0 and 1, TRIG_ACTIVE_LOW 0 and 1 | capture point, rate, trigger polarity |
| OVERRUN: hold the manager grant for 200 clocks, check no corrupted buffer | staging register |
| Triggered capture, SW_TRIG and pad | pre/post sample window |
| Manager arbitration with the FFT port busy (stub) | bandwidth share |
| Scan chain: shift test and ATPG of the whole SoC with the block in (AUS-26 regression) | DFT unaffected |

Acceptance for AUS-17: all of the above pass in RTL simulation, `make dft` and `make gls` pass with the block integrated
(AUS-18).

## 8. Plan inside the SPI window (26 Oct to 13 Nov)

1. Review of this spec and the open items below (by 30 Oct).
2. Flow experiment, **done 15 Oct**: a toy frame engine with the forwarded clock through synthesis, CTS and routing, same libraries and
   corners. It works without special handling (SCLK latency at the port 2.3 ns slow, duty error 0.16 ns, SDO setup +5.3 ns slow,
   RTL and routed-netlist simulation against the ADS7057 model pass). Forwarded clock is the default, `SCLK_HALF` stays as a register bit.
3. RTL and testbenches (AUS-17, 6 Nov), integration and firmware (AUS-18, 13 Nov).

## 9. Open items

Resolved with the datasheet (SBAS821) and the test board repository (`GitHub/adc_test_board`):

1. **ADS7057 clock mode.** SDO changes on SCLK rising edges, the host samples on falling edges, SCLK idles high, CS falling edge
   and the first falling edge are at least 7 ns apart (figures 2 and 37). The handoff called it "mode 1". A host with SCLK idle low should also
   work, because section 8.4.2 says the MSB is launched on the first rising edge after the first falling edge, but the figures show idle high and
   this was not tested, so the reader follows the figures. The earlier assumption of a configurable launch edge is removed from the register map and from the model.
2. **Trigger signal.** The latest board (v3, `doc/lowpower_plan.md`) has a window comparator that sets a latch: `WAKE_N` (open
   drain, pulled up to 3.3 V) goes low within 1 us of the first threshold crossing and **stays low until the host clears the
   latch** with `WAKE_CLR`. `BIG_N` flags a larger event. `CAP_EN` switches the supply of the capture chain (jumper selectable,
   default always on). So the trigger is a latched level, active low, and the chip needs one output to clear it. The ADC block
   gets `adc_wake_n_i`, `adc_big_n_i`, `adc_wake_clr_o`, `adc_cap_en_o` and a pins register. The first v2 board has a plain
   wired-OR `nWAKE` without latch, the same input works for it (no clear needed).
3. **Board interface.** PMOD pins v3: 1 CS, 3 SDO, 4 SCLK, 10 WAKE_N, 7 BIG_N, 8 WAKE_CLR, 2 CAP_EN, 9 spare, 3V3 on 6 and 12. 22 ohm
   series resistors on the SPI lines, 100 ohm on WAKE_N and BIG_N. No MOSI, no radio on this board. The board is 3.3 V (ADC DVDD from the
   PMOD, VIH = 0.65 DVDD, VOH up to DVDD). An AE burst lasts 26 to 83 us (real captures), shorter than a 128-sample buffer
   (148 us at 866 kS/s), so one buffer holds a whole event.

Still open:

4. **Level shifting for the chip.** The chip pads and the core run at 5 V (4.5 to 5.5 V corners). The ADC board is 3.3 V and its inputs
   take at most 3.6 V. A 3.3 to 5 V translator on CS, SCLK, SDO, WAKE_N, BIG_N, WAKE_CLR and CAP_EN (7 lines, fixed direction) is required for the
   Croc bring-up. The delay of a translator (about 5 ns each way) eats into the SDO setup budget, which has 5.3 ns of slack in the flow experiment, hence SDO_NEG.
5. **Forwarded clock to a pad.** Works in this flow (section 8, step 2). Chip level (pad ring, OpenSTA with the extracted timing
   model) is not tried: the generated clock has to be defined on the pad in the template SDC. Check at the first integration.
6. **Pre-trigger length.** How much time before the trigger the FFT needs. My assumption is one buffer of 128 samples
   (about 150 us at 866 kS/s). The window comparator fires on the first excursion, so the event start is already in the sampled
   buffer if the reader is free running.
7. **Radio pads (`rf_*`, DIO0, NRESET).** Not on the test board. Keep them in the spec, decide with the AFE board design.
   `adc_cap_en_o` is a hook for the power-gating research (AUS-21): it gates the capture chain of the board, not the chip.
8. **Anti-alias filter at 866 kS/s.** The low-pass on the test board is second order, f0 = 512 kHz, Q 0.71, made for 2.5 MS/s.
   Attenuation of the 2nd-order response, my calculation:

   | Sample rate | LPF at Nyquist | Content at the first alias band (just above Nyquist to 1.25 x fs) folds onto | Attenuation there |
   |---|---|---|---|
   | 2.5 MS/s | 15.6 dB | 625 kHz to 1.1 MHz | 17 to 23 dB |
   | 866 kS/s | 1.8 dB | 216 to 390 kHz (the event band) | 2.4 to 13 dB |

   So at 866 kS/s anything between 476 kHz and 1.1 MHz arrives in the 216 to 390 kHz event band with only 2 to 13 dB of
   attenuation. Whether this matters depends on the AE spectrum above 450 kHz. The real captures in the test board repository
   (`sim/listener_first_look.py`) can answer it. If it matters: a lower corner (the events peak at 233 to 275 kHz, so about 350 kHz
   costs about 1 dB there) or a higher sample rate (needs an SCLK above 18 MHz, not available from the 18 MHz core clock).
9. **Maximum SCLK through the pad (`bi_24t`) and the board.** The datasheet allows 60 MHz, the board 20 to 25 MHz, the pad at
   18 MHz with the board load has to be checked in the chip-level STA.
10. **RF FIFO depth.** 8 bytes is enough with stalling. 16 bytes costs 128 more flops and removes most stalls. Default: 8.
