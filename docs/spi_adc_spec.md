# SPI block for the ADC and the radio: specification v0.1 (AUS-16)

Status: draft for review, 15 Oct 2026. Nothing in this document is in RTL yet. Inputs: `Auselia_AFE_v1/doc/SPI_design_handoff.md`,
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

Ten new signals. The 0p5x1 slot has 44 bidirectional pads and 19 are used, so there is room.

| Pad (template `bidir[]`) | Signal | Direction | Note |
|---|---|---|---|
| 19 | `adc_sclk_o` | out | forwarded system clock, see section 6 |
| 20 | `adc_csn_o` | out | |
| 21 | `adc_sdo_i` | in | ADC data out |
| 22 | `adc_trig_i` | in | window comparator of the AFE board, optional |
| 23 | `rf_sclk_o` | out | |
| 24 | `rf_mosi_o` | out | |
| 25 | `rf_miso_i` | in | |
| 26 | `rf_csn_o` | out | |
| 27 | `rf_dio0_i` | in | radio done or RX interrupt, optional |
| 28 | `rf_rstn_o` | out | radio reset |

Template changes: `src/chip_core.sv` (mapping, `bidir_oe` for the outputs, spare pads pull-down), the two slot yaml files
(pad lists), and a new chip-level pad table in `TEST_PROCEDURE.md`. The macro `croc_soc` gets ten new ports.

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

### Frame

One sample is one CS-low frame of 18 SCLK clocks (the conversion needs 18 falling edges), then CS stays high for
`CS_HIGH` clocks (at least 95 ns, tacq). The result of a frame is the sample taken at the previous CS fall. The reader therefore:

- sends one calibration frame of 24 clocks at enable (datasheet: offset calibration after power-up), discarded,
- discards the first result of every start,
- stores the 14-bit two's complement code sign-extended to 16 bit.

| CS_HIGH (clocks) | Clocks per sample | Rate at 18.18 MHz (55 ns) | Rate at 20 MHz |
|---|---|---|---|
| 2 (110 ns at 18.18 MHz) | 20 | 909 kS/s | 1.00 MS/s |
| 3 (default) | 21 | 866 kS/s | 952 kS/s |
| 4 | 22 | 826 kS/s | 909 kS/s |

The FFT block wants at least 800 kS/s, the events need more than 550 kS/s (peaks at 233 to 275 kHz).

### Registers

| Offset | Name | Access | Fields |
|---|---|---|---|
| 0x100 | ADC_CTRL | RW | [0] EN, [1] RUN (1 = start, 0 = stop after the current frame), [2] TRIGGERED (capture one buffer after a trigger instead of free running), [3] SW_TRIG (write 1, self-clearing), [4] CAL (send a 24-clock calibration frame, self-clearing), [5] SW_RST (self-clearing), [11:8] CS_HIGH (clocks, min 2, default 3), [13:12] SAMPLE_DLY (0 to 2 extra clocks before MISO is sampled), [14] LAUNCH_FALLING (1 = ADC changes SDO on the falling edge), [15] SCLK_HALF (1 = SCLK is clk/2, fallback) |
| 0x104 | ADC_STATUS | R/W1C | [0] RUNNING, [1] BUF0_FULL, [2] BUF1_FULL, [3] OVERRUN (a buffer was still full when it had to be written), [4] BUS_ERROR (an OBI write got an error response), [5] DONE (triggered capture finished), [8] ACTIVE_BUF (RO, buffer being written) |
| 0x108 | ADC_BUF0 | RW | byte address of buffer 0 (word aligned, inside the SRAM) |
| 0x10C | ADC_BUF1 | RW | byte address of buffer 1 |
| 0x110 | ADC_NSAMP | RW | samples per buffer, even, 2 to 1024 (default 128) |
| 0x114 | ADC_IRQ_EN | RW | [0] BUF_FULL, [1] OVERRUN, [2] DONE |
| 0x118 | ADC_LAST | RO | most recent sample, sign-extended to 32 bit |
| 0x11C | ADC_COUNT | RO | samples stored since RUN (saturating) |

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
- The three ADC pad inputs and the trigger are double-synchronised. MISO is captured by a rising-edge flop of the
  system clock. SAMPLE_DLY and LAUNCH_FALLING move the capture point so that pad and board delay can be absorbed.

## 6. Clock, reset, test and flow

### SCLK of the ADC

At 18 MHz the half-rate clock (`SCLK_HALF`) gives only about 480 kS/s (9.1 MHz SCLK, 19 clocks per sample), below the event requirement. So the default is the system
clock forwarded to the pad through a latch-based clock gate (`tc_clk_gating`, the ICG cell the flow already uses), enabled by a
flop on the opposite phase so that SCLK has no glitches. SCLK high time and low time are one half clock period (50 % duty).

Consequences, all to be checked in the first flow run (section 8, step 2):

- The gate output feeds a pad, not flops. CTS treats the port as a clock sink. The SDC needs `create_generated_clock` on
  `adc_sclk_o` and output delays for CS relative to it, and an input delay for `adc_sdo_i` relative to the same clock.
- In scan mode the gate is forced open or closed by `testmode_i` so the pad is quiet and the chain is not affected.
- No negative-edge flops anywhere in the block. Scan, lock-up latches and the existing DFT flow stay as they are.
- Fallback if forwarding does not close: `SCLK_HALF`, which drops the rate to about 480 kS/s at 18.18 MHz.

### Reset, test, area

- One clock domain, `clk_i`, asynchronous reset `rst_ni` as the rest of the SoC, gated by `testmode_i` in the same way (AutoFix).
- Every flop is a normal scan flop. The block adds roughly 250 flops (registers about 120, FIFOs 128, counters about 60). My estimate.
- The RF master and the ADC reader do not share state. ADC_CTRL.EN = 0 and RF_CTRL.EN = 0 make the pads quiet.

## 7. Verification plan (AUS-17)

Behavioural models (simulation only) are in `verify/models/`: `ads7057_model.v`, `sx1276_model.v`, self-test `tb_models.v`
(passes). Bus testbench: OBI manager task from `croc_vip`, same style as `tb_fft_hwpe`.

| Test | What it proves |
|---|---|
| RF register reset values, byte, halfword, word access to every register | problem 1 and 2 of the WIP branch are gone |
| RF transfer of 1, 2, 8, 9, 300 bytes, modes 0 and 3, CLKDIV 0 and 24, against `sx1276_model` | stall and refill, CS timing, data integrity |
| RegVersion read (0x42 returns 0x12), FIFO write 3 bytes and TX mode, DIO0 interrupt | bring-up sequence |
| TX overflow, RX overrun, RX underflow flags, SW_RST during a transfer | error handling |
| ADC reader against `ads7057_model`: first frame discarded, calibration frame, 128-sample buffers, ping-pong, sign extension, packing | data path |
| ADC at CS_HIGH 2, 3, 4 and with SAMPLE_DLY 0 to 2, LAUNCH_FALLING 0 and 1 | capture point and rate |
| OVERRUN: hold the manager grant for 200 clocks, check no corrupted buffer | staging register |
| Triggered capture, SW_TRIG and pad | pre/post sample window |
| Manager arbitration with the FFT port busy (stub) | bandwidth share |
| Scan chain: shift test and ATPG of the whole SoC with the block in (AUS-26 regression) | DFT unaffected |

Acceptance for AUS-17: all of the above pass in RTL simulation, `make dft` and `make gls` pass with the block integrated
(AUS-18).

## 8. Plan inside the SPI window (26 Oct to 13 Nov)

1. Review of this spec and the open items below (by 30 Oct).
2. One-day flow experiment before the RTL is written: a toy design (counter, ICG, pad) through the Fusion Compiler flow to check that
   CTS and the SDC handle a forwarded clock to a port. The result decides `SCLK_HALF` or forwarded.
3. RTL and testbenches (AUS-17, 6 Nov), integration and firmware (AUS-18, 13 Nov).

## 9. Open items for you

1. **ADS7057 clock mode and launch edge.** The handoff says mode 1 (CPOL 0, CPHA 1), which means SDO changes on rising edges. TI SAR
   converters usually change SDO on falling edges and are read on the next rising edge. The datasheet timing diagram decides. The models and
   the reader support both, but the default value of `LAUNCH_FALLING` must be right. Please check SBAS821.
2. **Forwarded clock to a pad.** Not tried in this flow. Step 2 above settles it.
3. **Triggered capture.** What the AFE comparator signal looks like (level or pulse, polarity) and how much time before the trigger the
   FFT needs. My assumption is one buffer of 128 samples (about 150 us at 866 kS/s).
4. **Are DIO0, NRESET and the trigger wired on the board?** If not, pads 22, 27 and 28 are not needed.
5. **Maximum SCLK through the GF180 pads and the board level shifters.** The AFE document gives about 25 MHz for the board. The pad
   (`bi_24t`) must be checked at 18 MHz with the board load.
6. **RF FIFO depth.** 8 bytes is enough with stalling. 16 bytes costs 128 more flops and removes most stalls. Default: 8.
7. **Sample rate and the AFE anti-alias filter** (open item 3 of the FFT handoff): 866 kS/s is not the 2.5 MS/s the filter assumed.
