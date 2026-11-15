// ZedBoard demo, no ADC board: a tone in SRAM -> AE-FFT -> LoRa packet through the SX1276 (Pmod JD).
// 1. The SX1276 answers on SPI: RegVersion (0x42) must read 0x12.
// 2. A 128-sample tone at FFT bin TONE_BIN (14-bit codes, as the ADS7057 reader writes them) goes into the SRAM.
// 3. The FFT runs on it in place. PEAK_BIN must be TONE_BIN.
// 4. A 24-byte packet with the FFT features goes out over LoRa, NPKT times, one per second.
// The packet is the one of sim/sw/flash/ae_node.c: 0 'A', 1 sequence, 2 PEAK_BIN, 3 STATUS[5:2], 4..7 first
// buffer word, 8 PEAK_POW, 12 BAND_ENERGY, 16 TOTAL_ENERGY, 20 TD_ENERGY (little endian).
// Radio: 915 MHz (Chile, 915 to 928 MHz), LoRa SF7, BW 125 kHz, CR 4/5, explicit header, CRC on, sync word 0x12,
// PA_BOOST at about 14 dBm. A second SX1276 with the same settings receives it. For an 868 MHz or 433 MHz module,
// change FRF below.
// UART (Pmod JB, 115200 8N1): one line per step, then "FFT LORA OK" or "FFT LORA FAIL <mask>".
// Simulation (tb_croc_soc with its SX1276 model): DEFS="-DCLK_HZ=20000u -DNPKT=2" makes the waits 1000 times shorter.
// Load and run over JTAG (J-Link on Pmod JA): see README.md in this folder.
#include <stdint.h>
#include "uart.h"

#define TONE_BIN 36                                       // the tone generator below is for bin 36
#ifndef NPKT
#define NPKT 10
#endif
// RF carrier: FRF = f / (32 MHz / 2^19) = f / 61.035 Hz. 915 MHz -> 0xE4C000, 868 MHz -> 0xD90000, 433 MHz -> 0x6C4000
#ifndef FRF
#define FRF 0xE4C000u
#endif

#define SPI_BASE  0x22000000u
#define FFT_BASE  0x22001000u
#define SPI(o)    (*(volatile uint32_t *)(SPI_BASE + (o)))
#define FFT(o)    (*(volatile uint32_t *)(FFT_BASE + (o)))

#define RF_CTRL   0x00
#define RF_STATUS 0x04
#define RF_CMD    0x08
#define RF_DATA   0x0C
#define RF_IRQ_ST 0x14
#define RF_PINS   0x18
#define RF_ERR    0x1C
#define ST_TX_FULL  (1u << 2)
#define ST_RX_EMPTY (1u << 3)
#define IRQ_DONE    (1u << 0)
#define IRQ_DIO0    (1u << 4)

#define F_CTRL     0x00
#define F_STATUS   0x04
#define F_SRC      0x08
#define F_SETUP0   0x18
#define F_SETUP1   0x1C
#define F_THRESH   0x20
#define F_PEAK_BIN 0x24
#define F_PEAK_POW 0x28
#define F_BAND     0x2C
#define F_TOTAL    0x30
#define F_TD       0x34

// 128 samples (256 B) above the code, below the stack (192 B) at the top of the 2 KB SRAM. build.sh checks that
// the code and its data end below BUF.
#define BUF 0x10000640u

#ifndef CLK_HZ
#define CLK_HZ  20000000u                                  // the ZedBoard MMCM gives croc 20 MHz
#endif
#define TIMEOUT (2u * CLK_HZ)

static uint32_t mcycle(void) {
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}
static void put(const char *s) { while (*s) uart_write(*s++); }
static void put_hex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]); }

static uint32_t fail;

// one SPI transfer of n bytes to the radio, received bytes in rx (rx = 0: dropped)
static void rf_xfer(const uint8_t *tx, uint8_t *rx, uint32_t n) {
    uint32_t i = 0, j = 0, t0 = mcycle();
    SPI(RF_CMD) = n;
    while (j < n) {
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 2; return; }
        uint32_t st = SPI(RF_STATUS);
        if (i < n && !(st & ST_TX_FULL)) {
            SPI(RF_DATA) = tx[i++];
        } else if (!(st & ST_RX_EMPTY)) {
            uint8_t b = (uint8_t)SPI(RF_DATA);
            if (rx) rx[j] = b;
            j++;
        }
    }
    while (!(SPI(RF_IRQ_ST) & IRQ_DONE))
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 2; return; }
    SPI(RF_IRQ_ST) = IRQ_DONE;
}
static void rf_wr(uint8_t a, uint8_t v) { uint8_t b[2] = {(uint8_t)(0x80u | a), v}; rf_xfer(b, 0, 2); }
static uint8_t rf_rd(uint8_t a) { uint8_t b[2] = {a, 0}, r[2] = {0, 0}; rf_xfer(b, r, 2); return r[1]; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void wait_cycles(uint32_t n) { uint32_t t = mcycle(); while (mcycle() - t < n) {} }

static uint8_t pkt[25];                                    // 0x80 (FIFO write) + 24 payload bytes

int main() {
    uart_init();
    put("FFT LORA demo\n");

    // 1. radio: reset pulse, SPI at clk / 4 (5 MHz), then RegVersion
    SPI(RF_PINS) = 0u;  wait_cycles(CLK_HZ / 1000);       // RESET low 1 ms
    SPI(RF_PINS) = 1u;  wait_cycles(CLK_HZ / 100);        // 10 ms for the radio to start
    SPI(RF_CTRL) = 1u | (1u << 8) | (1u << 16);
    uint8_t ver = rf_rd(0x42);
    put("radio version "); put_hex(ver); put("\n");
    if (ver != 0x12) fail |= 1u << 0;
    rf_wr(0x01, 0x80);                                     // RegOpMode: LoRa, sleep
    rf_wr(0x06, (FRF >> 16) & 0xFF);                       // RegFrfMsb
    rf_wr(0x07, (FRF >> 8) & 0xFF);                        // RegFrfMid
    rf_wr(0x08, FRF & 0xFF);                               // RegFrfLsb
    rf_wr(0x09, 0x8C);                                     // RegPaConfig: PA_BOOST, about 14 dBm
    rf_wr(0x01, 0x81);                                     // LoRa, standby
    rf_wr(0x1D, 0x72);                                     // RegModemConfig1: BW 125 kHz, CR 4/5, explicit header
    rf_wr(0x1E, 0x74);                                     // RegModemConfig2: SF7, CRC on
    rf_wr(0x0E, 0x80);                                     // RegFifoTxBaseAddr
    rf_wr(0x22, 24);                                       // RegPayloadLength
    rf_wr(0x40, 0x40);                                     // RegDioMapping1: DIO0 = TxDone

    // 2. tone at bin TONE_BIN, amplitude 3000 codes: y[n] = 2 cos(w) y[n-1] - y[n-2] in Q14 (no math library)
    //    2^14 cos(2 pi 36 / 128) = -3196, y[1] = round(3000 sin(2 pi 36 / 128)) = 2942. Croc has no multiplier
    //    (rv32i): 3196 y = (2048 + 1024 + 64 + 32 + 16 + 8 + 4) y in shifts, so no libgcc multiply is linked.
    int32_t y0 = 0, y1 = 2942;
    volatile uint16_t *s = (volatile uint16_t *)BUF;
    for (int n = 0; n < 128; n++) {
        s[n] = (uint16_t)(y0 & 0x3FFF);                    // 14-bit two's complement, as the ADC reader writes
        int32_t m = (y1 << 11) + (y1 << 10) + (y1 << 6) + (y1 << 5) + (y1 << 4) + (y1 << 3) + (y1 << 2);
        int32_t y2 = -(m >> 13) - y0;                      // 2 cos(w) y[n-1] - y[n-2]
        y0 = y1; y1 = y2;
    }

    // 3. FFT: 14-bit samples, gain 2^2, band bins 32..39 (as ae_node.c)
    FFT(F_SETUP0) = 2u | (4u << 8);
    FFT(F_SETUP1) = 3u | (32u << 8) | (39u << 16);
    FFT(F_THRESH) = 179u | (192u << 8);
    uint32_t tag = *(volatile uint32_t *)BUF, st, t1 = mcycle();
    FFT(F_SRC) = BUF;
    FFT(F_STATUS) = 0x46;                                  // clear DONE, SAT, ERROR
    FFT(F_CTRL) = 1u | 2u;                                 // START, CLR_PREV
    while (!((st = FFT(F_STATUS)) & 2u))
        if (mcycle() - t1 > TIMEOUT) { fail |= 1u << 1; break; }
    uint32_t peak = FFT(F_PEAK_BIN);
    put("fft peak bin "); put_hex(peak); put(" cycles "); put_hex(mcycle() - t1); put("\n");
    if (peak != TONE_BIN) fail |= 1u << 3;
    if (st & (1u << 6)) fail |= 1u << 1;
    put32(&pkt[9],  FFT(F_PEAK_POW));
    put32(&pkt[13], FFT(F_BAND));
    put32(&pkt[17], FFT(F_TOTAL));
    put32(&pkt[21], FFT(F_TD));

    // 4. NPKT packets, one per second
    for (uint32_t seq = 0; seq < NPKT; seq++) {
        pkt[0] = 0x80; pkt[1] = 'A'; pkt[2] = (uint8_t)seq; pkt[3] = (uint8_t)peak;
        pkt[4] = (uint8_t)((st >> 2) & 0xFu);
        put32(&pkt[5], tag);
        rf_wr(0x0D, 0x80);                                 // FifoAddrPtr = TX base
        rf_xfer(pkt, 0, 25);
        rf_wr(0x01, 0x83);                                 // LoRa, TX
        uint32_t t2 = mcycle();
        while (!(SPI(RF_IRQ_ST) & IRQ_DIO0))
            if (mcycle() - t2 > TIMEOUT) { fail |= 1u << 4; break; }
        rf_wr(0x12, 0x08);                                 // clear TxDone in the radio
        SPI(RF_IRQ_ST) = IRQ_DIO0;
        put("tx "); put_hex(seq); put(" airtime cycles "); put_hex(mcycle() - t2); put("\n");
        wait_cycles(CLK_HZ);
    }
    if (SPI(RF_ERR) != 0u) fail |= 1u << 5;

    if (fail) { put("FFT LORA FAIL "); put_hex(fail); put("\n"); }
    else put("FFT LORA OK\n");
    uart_write_flush();
    return (int)fail;
}
