# ZedBoard bring-up of croc, step by step

Small test programs, each one printing its results on the UART and ending with `STEPn OK` or `STEPn FAIL <mask>`
(step 2: `QSPI CMD OK` / `QSPI CMD FAIL <mask>`). Do the steps in order: each step uses only hardware that the steps
before it have shown to work.

- Steps 0, 1, 2 run from croc's 2 KB SRAM, loaded over JTAG (J-Link on Pmod JA): they come before the QSPI is proven.
- Steps 3 to 6 run from the QSPI flash (execute in place, `../flash/link_flash.ld`): code in the flash, data, buffers
  and stack in the SRAM. croc has no cache: code from the flash runs at about 130 clocks per word (single SPI), about
  0.15 MIPS at 20 MHz. That is enough here, the FFT is hardware. To program the flash, OpenOCD writes the image into
  PSRAM A, and the flasher (step 2b, in the SRAM) copies it into the flash. Then croc resets and the bootrom finds the
  magic word "CROC" at flash address 0 and runs the program from there. `load.sh` does all of it.

**Warning: plug in the AFE v1 board only with the bitstream of 7 Nov 2026 or later.** The older bitstream drives two
of the pins that the AFE board drives.

| Step | Program | Runs from | Test | New hardware |
|---|---|---|---|---|
| 0 | `s0_hello` | SRAM | UART, GPIO on LD0/LD1 (read back through the pad), mcycle, 32.768 kHz mtime | J-Link, FTDI |
| 1 | `s1_fft` | SRAM | FFT on a tone at bin 36 in SRAM | none |
| 2 | `s2_qspi` | SRAM | flash JEDEC ID, erase, program, read, stores, QE bit, both PSRAMs single and quad | QSPI Pmod |
| 2b | `s2b_flasher` | SRAM | PSRAM A -> flash, read back (used by steps 3 to 6) | none |
| 3 | `s3_adc` | flash | 128 ADC samples: format, min, max, mean | AFE v1 |
| 4 | `s4_lora` | flash | RegVersion, NPKT packets, TxDone on DIO0 | SX1276, a second SX1276 |
| 5 | `s5_adc_fft` | flash | ADC block, FFT, features (5 blocks) | none new |
| 6 | `s6_adc_fft_lora` | flash | ADC block, FFT, features sent over LoRa (5 blocks) | none new |
| 7 | `s7_event` | flash | WAKE_N-triggered capture, FFT per block (BAND_OK, DECAY), envelope features | AFE v1, a signal |

## 1. Where every croc port goes

All Pmods are 3.3 V (bank 13). Pmod pins 5 and 11 are GND, 6 and 12 are 3.3 V. Pins from Digilent's
`Zedboard-Master.xdc`. JE is not usable: it is the MIO Pmod of the Zynq processor side.

| croc port | Dir | Board | Pmod pin | FPGA pin | Notes |
|---|---|---|---|---|---|
| `clk_i` | in | 100 MHz oscillator, MMCM | | Y9 | 20 MHz |
| `rst_ni` | in | BTNC | | P16 | press = reset. Also in reset until the MMCM locks |
| `ref_clk_i` | in | internal | | | 20 MHz / 610 = 32.787 kHz |
| `testmode_i` | in | 0 | | | |
| `status_o` | out | LD2 | | U22 | |
| `jtag_tck_i` | in | J-Link TCK | JA1 | Y11 | |
| `jtag_tms_i` | in | J-Link TMS | JA2 | AA11 | pull-up |
| `jtag_tdi_i` | in | J-Link TDI | JA3 | Y10 | pull-up |
| `jtag_tdo_o` | out | J-Link TDO | JA4 | AA9 | |
| `jtag_trst_ni` | in | J-Link nTRST | JA7 | AB11 | pull-up |
| | | J-Link VTref / GND | JA6 / JA5 | | |
| `uart_tx_o` | out | UART receiver (AD2 DIO 0) | JB1 | W12 | **125000** 8N1, see section 7 |
| `uart_rx_i` | in | (not used by the steps) | JB2 | W11 | |
| `qspi_csn_o[0]` | out | flash CS | JC1 | AB7 | QSPI Pmod (TinyTapeout), plugs in directly |
| `qspi_sd[0]` | io | SD0 / MOSI | JC2 | AB6 | |
| `qspi_sd[1]` | io | SD1 / MISO | JC3 | Y4 | |
| `qspi_clk_o` | out | SCK | JC4 | AA4 | |
| `qspi_sd[2]` | io | SD2 / WP | JC7 | R6 | |
| `qspi_sd[3]` | io | SD3 / HOLD | JC8 | T6 | |
| `qspi_csn_o[1]` | out | PSRAM A CS | JC9 | T4 | |
| `qspi_csn_o[2]` | out | PSRAM B CS | JC10 | U4 | |
| `spi_sck_o` | out | radio SCK | JB3 | V10 | also ADC SCLK (JD10) |
| `spi_sd_o` | out | radio MOSI | JB4 | W8 | |
| `spi_sd_i` | in | radio MISO | JB7 | V12 | pull-up. ADC SDO (JD9) while the ADC CS is low |
| `spi_cs1_o` | out | radio NSS | JB8 | W10 | |
| `rf_rstn_o` | out | radio RESET | JB9 | V9 | |
| `rf_dio0_i` | in | radio DIO0 | JB10 | V8 | pull-down. Also LD6 |
| `spi_cs0_o` | out | AFE CS | JD7 | W6 | |
| `spi_sd_i` | in | AFE SDO | JD9 | U6 | pull-down |
| `spi_sck_o` | out | AFE SCLK | JD10 | U5 | |
| `afe_irq_i` | in | AFE WAKE_N | JD4 | V4 | pull-up (open drain). Also LD4 |
| (none) | in | AFE BIG_N | JD1 | V7 | pull-up (open drain). Not a croc port: LD5 only |
| `gpio[0]`, `gpio[1]` | io | LD0, LD1 | | T22, T21 | |

croc has one SPI master for the ADC and the radio, as on the chip. `rtl/fpga/croc_zedboard_top.sv` copies SCK to
both Pmods and takes MISO from the ADC while the ADC CS is low, else from the radio.

AFE v1 board: it plugs into JD upside down, board pin n lands on JD pin (n + 6) mod 12. GND and 3.3 V stay correct
(5/11 and 6/12 swap with each other). Board pins 2, 8, 9 are not connected. The board has no WAKE_CLR or CAP_EN.

Other LEDs: LD3 = reset released (the bitstream runs), LD7 = heartbeat (about 0.6 s). Switches and the other buttons
are not used.

The SX1276 needs an antenna (or a 50 ohm load) before step 4.

## 2. Bitstream

On microelectronica-win: `C:\Users\navillegas\croc_fpga\work_fpga\croc_zedboard_top.bit` (`make fpga`,
`scripts/fpga/build_zedboard.tcl`). Program it over the ZedBoard PROG USB, with Vivado Hardware Manager on that PC, or
with OpenOCD on the Mac:

```bash
openocd -f board/digilent_zedboard.cfg -c "init; pld load 0 croc_zedboard_top.bit; shutdown"
```

After programming: LD3 on, LD7 blinks.

## 3. Build and load a step

Build on Rocky, in this folder, then copy `bin/` to the Mac (next to `load.sh` and `openocd-croc.cfg`):

```bash
./build.sh s0_hello
```

For steps 3 to 6 also build the flasher once: `./build.sh s2b_flasher`. Options: `./build.sh s4_lora -DNPKT=100`,
`-DFRF=0xD90000u` (868 MHz) or `-DFRF=0x6C4000u` (433 MHz) for steps 4 and 6, `-DNBLK=20` for steps 5 and 6,
`-DADC_SDO_POS` for steps 3, 5, 6 if the ADC samples are garbage (SDO into the rising-edge flop instead of the
falling-edge one).

Load and run on the Mac (OpenOCD 0.12, J-Link on JA), with the UART open at 115200 8N1:

```bash
./load.sh s0_hello
```

For steps 3 to 6, `./load.sh s3_adc` writes `bin/s3_adc.psram.bin` into PSRAM A, runs the flasher (UART:
`STEP2b flasher`, `length ...`, `FLASH WRITE OK <length>`) and resets croc, which then boots the step from the flash.
The flash keeps the step: BTNC (or `./load.sh boot`) runs it again. Press BTNC between SRAM steps.

## 4. What to expect per step

**Step 0** (`STEP0 bring-up`): LD0 and LD1 blink in turn 5 times, then `mcycle` about 00989680 (0.5 s),
`mtime` about 00004000. FAIL bits: 0 GPIO read back, 1 mcycle, 2 mtime rate.

**Step 1** (`STEP1 fft`): `peak bin 00000024` (bin 36). FAIL bits: 0 timeout, 1 FFT error, 2 wrong peak bin.

**Step 2**: nothing printed when every check passes, then `QSPI CMD OK`. A failing check prints `step <n> got <value>`.
FAIL bits: 1 JEDEC ID (expect EF4018), 2 erase, 3 page program, 4 stores into the flash window, 5 QE bit,
6 PSRAM (ID 0D 5D, single and quad), 7 timeout. It writes the flash sector at 0x010000.

**Step 2b** (flasher, before steps 3 to 6): `FLASH WRITE OK <length>`. FAIL bits: 1 no image in PSRAM A (length or
"CROC" magic wrong: check the `load_image ... 0x21000000 bin`), 2 read-back mismatch (`mismatch at <offset>`),
7 timeout. It erases and writes the flash from address 0.

**Step 3** (`STEP3 adc`): `adc status`, `adc count` (at least 00000080: 128 samples, plus the ones of the frame that
ends after the stop), the first 16 samples (14-bit two's complement
codes, sign-extended to 16 bits), then `min`, `max`, `mean`. With the AFE input open you see the noise floor around
the mid code. FAIL bits: 0 no full block, 1 bus error, 2 sample format, 3 all samples equal (SDO stuck: check JD9).
LD4 and LD5 show WAKE_N and BIG_N.

**Step 4** (`STEP4 lora`): `radio version 00000012`, then one `tx airtime` line per packet, about 36 ms at SF7 and
8 bytes (about 0x000B0000 cycles). LD6 flashes at each TxDone. Packet: 'L',
sequence, A5 5A C3 3C 0F F0. FAIL bits: 0 RegVersion (check JB wiring and power), 1 no TxDone on DIO0 (check JB10),
2 SPI timeout, 3 rf_spi error.

**Step 5** (`STEP5 adc fft`): per block the FFT features (`peak bin`, `peak pow`, `band energy`, `total energy`,
`td energy`). FAIL bits: 1 ADC block, 2 FFT, 6 ADC bus error.

**Step 6** (`STEP6 adc fft`): `radio version`, then per block `peak bin` and `tx <airtime>` (about 62 ms for 24 bytes, 0x0012D000 cycles). The 24-byte packet is
the one of `sim/sw/fpga_fft_lora`: 0 'A', 1 block, 2 PEAK_BIN, 3 FFT status, 4..7 first sample word, 8 PEAK_POW,
12 BAND_ENERGY, 16 TOTAL_ENERGY, 20 TD_ENERGY (little endian). FAIL bits: 0 RegVersion, 1 ADC block, 2 FFT,
4 no TxDone, 5 radio SPI, 6 ADC bus error.

## 5. The receiver (steps 4 and 6)

A second SX1276: 915 MHz (FRF 0xE4C000), LoRa, SF7, BW 125 kHz, CR 4/5, explicit header, CRC on, sync word 0x12.
Payload 8 bytes (step 4) or 24 bytes (step 6).

## 6. Simulation

`~/Documents/run_bringup_sim.sh` on Rocky runs every step in the RTL testbench (`tb_croc_soc`, with the ADS7057,
SX1276, W25Q and APS6404L models), with short waits (`-DCLK_HZ=20000u -DTIMEOUT=2000000u -DNPKT=2 -DNBLK=2`). Steps 3
to 6 go through the whole board path: the flasher (`-DBOOT`) is loaded over JTAG, PSRAM A is preloaded with
`bin/<step>.psram.hex` (as OpenOCD writes it), the flasher writes the flash and jumps to the program. Step 3 uses
`-DRAMP` (the model ramp), steps 5 and 6 `-DEXPECT_BIN=36` with `+adc_tone=36`, step 0 `-DNO_GPIO_READBACK` (the
testbench GPIO model does not loop back).

croc stores words in the PSRAM most significant byte first. The `.psram.hex` for the model is in that order, the
`.psram.bin` for OpenOCD is not (OpenOCD writes through croc).

## 7. Board findings (9 Nov 2026)

- **UART rate:** croc sends at 125000 baud, not 115200: `uart_init` truncates 20 MHz / (16 x 115200) = 10.85 to 10
  (measured 8.0 us per bit with `ad2_bittime.py`). A 115200 receiver reads garbage. The steps are read with an Analog
  Discovery 2: DIO 0 on JB1, GND on JB5, `python3 ad2_uart.py <seconds> <log>` (close the WaveForms app first). The
  J-Link VCOM does not work for it (garbled, and its pin 5 is TDI: it breaks JTAG).
- **QSPI flash commands in SPI mode 3:** when a command of the engine ends, `user_domain.sv` gives the pins back to
  obi_qspi in the same cycle that CS rises, and the idle SCLK of obi_qspi is 1. In mode 0 that is a rising SCLK edge
  at the CS rise, the W25Q counts a 9th clock and drops every command it runs at CS rise (write enable, erase,
  program, status write, reset). Reads work. Step 2 and the flasher send flash commands in mode 3 (the PSRAMs pass in
  mode 0). The RTL fix is open. The simulation flash model does not catch it.
- **Flash ID:** the Pmod has a W25Q128JV-IM/JM, ID EF7018 (step 2 accepts EF4018 and EF7018).
- **SRAM steps:** their crt0 does not clear .bss, so each step sets `fail = 0`. `load.sh` sets ra to the bootrom
  `_eoc` (0x0200_0100), or main returns to a stale ra and the step runs again.
- **GPIO:** the input register reads 0 for a pin set as an output, so step 0 has no read-back check: watch LD0/LD1.
- **Builds:** `~/Documents/run_bringup_sim.sh` builds the simulation versions (`-DCLK_HZ=20000u`) into the same `bin/`.
  Build the board versions after it (`./build.sh <step>`), or the waits are 1000 times too short on the board.

## 8. Bench tools (MSOX4024A over LAN, AD2)

| Tool | Use |
|---|---|
| `scope.py` | SCPI to the MSOX4024A (192.168.140.102:5025), for example `python3 scope.py ":WGEN:OUTP 0"` |
| `ad2_uart.py`, `ad2_bittime.py` | UART receiver on AD2 DIO 0, and the bit time on the line |
| `adc_point.sh`, `adc_fit.py` | one frequency-response point: WaveGen sine, step 3 with `-DDUMP=8` in the flash, sine fit of the blocks |
| `wake_probe.tcl` | WAKE_N flag and pin level through croc over JTAG |
| `trig_test.tcl` | the WAKE_N-triggered ADC capture set up over JTAG, no program |
| `flash_status.tcl` | W25Q JEDEC ID and status registers through the command engine over JTAG |
| `cav_arb.py`, `cav_run.sh`, `cav_compare.py` | a scope capture played by the WaveGen (8192 points, 4 kHz): the ADC and FFT of croc against the expected chain |
| `event_arb.py`, `event_run.sh`, `event_check.py` | step 7: synthetic hits or captures played once per 2 ms, the FFT checked against `sim/fft/model/aefft_model.py`, the envelope features recomputed |
| `gen_dash_data.py` | the CSV files of the results page from the logs |

The tools that use numpy need a Python 3 with numpy (on the Mac: a venv).

Step 7 on the board (9 Nov 2026): the FFT equals the model and the envelope features equal the recomputed ones on
every event. 250 kHz hit (20 us rise, 80 us decay): rise 15 to 16 us, fall 173 to 176 us, duration 68 to 70 us (ideal
16, 177, 69), BAND_OK, DECAY on blocks 1 to 3. 120 kHz hit: no BAND_OK. Cavitation captures: BAND_OK, duration 247 to
250 us for a 250 us capture, rise and fall not meaningful (steady noise). Spike captures (00003, 00007): no WAKE_N,
below the listener threshold after the AFE.
