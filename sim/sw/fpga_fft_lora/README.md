# ZedBoard demo: FFT and LoRa over JTAG

croc on the ZedBoard generates a tone in its SRAM, runs the FFT accelerator on it and sends the result as LoRa packets
through an SX1276 module to a second SX1276. No ADC board and no flash programming are needed: the J-Link loads the
program into the SRAM. The flash Pmod can stay plugged in.

## 1. Wiring

All Pmods are 3.3 V. Pin 5 of every Pmod is GND, pin 6 is 3.3 V.

| Pmod | Pin | Signal | Connect to |
|---|---|---|---|
| JA | 1, 2, 3, 4, 7 | TCK, TMS, TDI, TDO, TRST | J-Link TCK, TMS, TDI, TDO, nTRST. J-Link VTref to 3.3 V (JA6), GND to JA5 |
| JB | 1, 2 | UART TX, RX (croc side) | USB-UART adapter RX, TX. 115200 8N1 |
| JC | all | QSPI flash Pmod | unchanged, it can stay connected |
| JD | 1 | SCK | SX1276 SCK |
| JD | 2 | MOSI | SX1276 MOSI |
| JD | 3 | MISO | SX1276 MISO |
| JD | 4 | NSS | SX1276 NSS (CS) |
| JD | 7 | RESET | SX1276 RESET (RST) |
| JD | 8 | DIO0 | SX1276 DIO0 |
| JD | 5, 6 | GND, 3.3 V | SX1276 GND, 3.3 V |
| JD | 9, 10 | ADC CS, AFE WAKE_N | free until the ADS7057 board arrives |

The module needs an antenna (or a 50 ohm load) before it transmits.

## 2. Bitstream

On microelectronica-win: `C:\Users\navillegas\croc_fpga\work_fpga\croc_zedboard_top.bit` (`make fpga` builds it,
scripts/fpga/build_zedboard.tcl). Two ways to program it over the ZedBoard USB-JTAG (PROG port):

- Vivado Hardware Manager on microelectronica-win, with the PROG USB on that PC.
- OpenOCD on the Mac (Vivado does not run on macOS), with the bitstream copied over:
  `openocd -f board/digilent_zedboard.cfg -c "init; pld load 0 croc_zedboard_top.bit; shutdown"`

LD2 is croc's status_o.

## 3. Load and run

On the Mac, in this folder (OpenOCD 0.12, as in August):

```bash
openocd -f openocd-croc.cfg -c "load_image bin/fft_lora.elf; verify_image bin/fft_lora.elf; reg pc 0x1000000c; resume; shutdown"
```

`bin/fft_lora.elf` comes from `./build.sh` (on Rocky). Other bands: `DEFS=-DFRF=0xD90000u ./build.sh` for 868 MHz,
`-DFRF=0x6C4000u` for 433 MHz. More packets: `-DNPKT=100`.

## 4. What to expect

UART, at 115200:

```
FFT LORA demo
radio version 00000012        <- the SX1276 answers on the SPI bus (anything else: check JD wiring and power)
fft peak bin 00000024         <- bin 36 (0x24), the tone
tx 00000000 airtime cycles ...
...
FFT LORA OK
```

`FFT LORA FAIL <mask>`: bit 0 no radio (RegVersion), 1 FFT error or timeout, 2 SPI timeout, 3 wrong peak bin,
4 no TxDone on DIO0, 5 radio SPI error.

## 5. The receiver

A second SX1276 with the same settings: 915 MHz (FRF 0xE4C000), LoRa, SF7, BW 125 kHz, CR 4/5, explicit header,
CRC on, sync word 0x12, payload 24 bytes. Packet (little endian): 0 'A', 1 sequence, 2 PEAK_BIN, 3 FFT status,
4..7 first sample word, 8 PEAK_POW, 12 BAND_ENERGY, 16 TOTAL_ENERGY, 20 TD_ENERGY. Ten packets, one per second.
