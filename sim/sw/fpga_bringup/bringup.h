// Shared helpers of the ZedBoard bring-up steps (sim/sw/fpga_bringup). Only static functions: each step links what it
// uses (--gc-sections). Register maps as in sim/sw/fpga_fft_lora/fft_lora.c, sim/sw/spi/spi_adc.c and
// sim/sw/flash/ae_node.c.
#include <stdint.h>
#include "uart.h"

#ifndef CLK_HZ
#define CLK_HZ  20000000u                                  // the ZedBoard MMCM gives croc 20 MHz
#endif
#ifndef TIMEOUT
#define TIMEOUT (2u * CLK_HZ)                              // simulation with a short CLK_HZ: -DTIMEOUT=2000000u
#endif

#define SPI_BASE  0x22000000u
#define FFT_BASE  0x22001000u
#define GPIO_BASE 0x03005000u
#define CLINT_MTIME 0x0204BFF8u
#define SPI(o)    (*(volatile uint32_t *)(SPI_BASE + (o)))
#define FFT(o)    (*(volatile uint32_t *)(FFT_BASE + (o)))
#define GPIO(o)   (*(volatile uint32_t *)(GPIO_BASE + (o)))
#define MTIME     (*(volatile uint32_t *)CLINT_MTIME)

// radio SPI (rf_spi)
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
// ADS7057 reader
#define ADC_CTRL   0x100
#define ADC_STATUS 0x104
#define ADC_BUF0   0x108
#define ADC_BUF1   0x10C
#define ADC_NSAMP  0x110
#define ADC_COUNT  0x11C
#define A_EN       (1u << 0)
#define A_RUN      (1u << 1)
#define A_IDLE(n)  ((uint32_t)(n) << 8)
#define A_SDO_NEG  (1u << 12)
#define A_TRIG_LOW (1u << 14)
#define A_RUNNING  (1u << 0)
#define A_FULL0    (1u << 1)
#define A_FULL1    (1u << 2)
#define A_OVERRUN  (1u << 3)
#define A_BUSERR   (1u << 4)
// SDO into the falling-edge flop, as on the chip. -DADC_SDO_POS for the rising edge if the board reads garbage.
#ifdef ADC_SDO_POS
#define A_MODE (A_EN | A_TRIG_LOW | A_IDLE(2))
#else
#define A_MODE (A_EN | A_TRIG_LOW | A_SDO_NEG | A_IDLE(2))
#endif
// FFT
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

#ifdef XIP
// Steps 3 to 6 run from the QSPI flash (link_flash.ld): code in the flash, the buffers in the SRAM .bss.
static uint16_t adc_buf0[128] __attribute__((aligned(4)));
static uint16_t adc_buf1[128] __attribute__((aligned(4)));
#define BUF0 ((uint32_t)adc_buf0)
#define BUF1 ((uint32_t)adc_buf1)
#else
// Run from the SRAM. BUF0: 128 samples (256 B) below the stack (top 192 B of the 2 KB SRAM). BUF1 only takes the
// samples of the frame that ends after RUN = 0 (adc_block). build.sh checks that the code and data end below BUF0.
#define BUF0 0x10000640u
static uint16_t adc_tail[16];
#define BUF1 ((uint32_t)adc_tail)
#endif

#ifndef FRF
#define FRF 0xE4C000u                                      // 915 MHz. 868 MHz 0xD90000, 433 MHz 0x6C4000
#endif
#ifndef NPKT
#define NPKT 10
#endif

static uint32_t fail;

static uint32_t mcycle(void) { uint32_t v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }
static void wait_cycles(uint32_t n) { uint32_t t = mcycle(); while (mcycle() - t < n) {} }
static void put(const char *s) { while (*s) uart_write(*s++); }
static void put_hex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]); }
static void kv(const char *k, uint32_t v) { put(k); put(" "); put_hex(v); put("\n"); }
static void check(int bit, int ok, const char *what) { if (!ok) { fail |= 1u << bit; put("  fail: "); put(what); put("\n"); } }
static int finish(const char *name) {
    put(name); if (fail) { put(" FAIL "); put_hex(fail); } else put(" OK"); put("\n");
    uart_write_flush();
    return (int)fail;
}

// ---- radio ----
static void rf_xfer(const uint8_t *tx, uint8_t *rx, uint32_t n) {
    uint32_t i = 0, j = 0, t0 = mcycle();
    SPI(RF_CMD) = n;
    while (j < n) {
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 30; return; }
        uint32_t st = SPI(RF_STATUS);
        if (i < n && !(st & ST_TX_FULL)) SPI(RF_DATA) = tx[i++];
        else if (!(st & ST_RX_EMPTY)) { uint8_t b = (uint8_t)SPI(RF_DATA); if (rx) rx[j] = b; j++; }
    }
    while (!(SPI(RF_IRQ_ST) & IRQ_DONE)) if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 30; return; }
    SPI(RF_IRQ_ST) = IRQ_DONE;
}
static void rf_wr(uint8_t a, uint8_t v) { uint8_t b[2] = {(uint8_t)(0x80u | a), v}; rf_xfer(b, 0, 2); }
static uint8_t rf_rd(uint8_t a) { uint8_t b[2] = {a, 0}, r[2] = {0, 0}; rf_xfer(b, r, 2); return r[1]; }
// reset, SPI at clk / 4, LoRa 915 MHz SF7 BW 125 kHz CR 4/5 CRC on, PA_BOOST about 14 dBm, DIO0 = TxDone.
// Returns RegVersion (0x12 for an SX1276).
static uint8_t rf_init(uint8_t len) {
    SPI(RF_PINS) = 0u; wait_cycles(CLK_HZ / 1000);
    SPI(RF_PINS) = 1u; wait_cycles(CLK_HZ / 100);
    SPI(RF_CTRL) = 1u | (1u << 8) | (1u << 16);
    uint8_t ver = rf_rd(0x42);
    static const uint8_t cfg[] = {
        0x01, 0x80,                                        // RegOpMode: LoRa, sleep
        0x06, (FRF >> 16) & 0xFF, 0x07, (FRF >> 8) & 0xFF, 0x08, FRF & 0xFF,   // RegFrf
        0x09, 0x8C,                                        // RegPaConfig: PA_BOOST, about 14 dBm
        0x01, 0x81,                                        // LoRa, standby
        0x1D, 0x72, 0x1E, 0x74,                            // BW 125 kHz, CR 4/5, explicit header / SF7, CRC on
        0x0E, 0x80, 0x22, 0,                               // RegFifoTxBaseAddr, RegPayloadLength (set below)
        0x40, 0x40,                                        // RegDioMapping1: DIO0 = TxDone
    };
    for (uint32_t i = 0; i < sizeof cfg; i += 2) rf_wr(cfg[i], i == 20 ? len : cfg[i + 1]);
    return ver;
}
// p[0] must be 0x80 (FIFO write), then len payload bytes. Returns the airtime in cycles, 0 on no TxDone.
static uint32_t rf_send(uint8_t *p, uint32_t len) {
    rf_wr(0x0D, 0x80);
    rf_xfer(p, 0, len + 1);
    rf_wr(0x01, 0x83);
    uint32_t t = mcycle();
    while (!(SPI(RF_IRQ_ST) & IRQ_DIO0)) if (mcycle() - t > TIMEOUT) return 0;
    t = mcycle() - t;
    rf_wr(0x12, 0x08);
    SPI(RF_IRQ_ST) = IRQ_DIO0;
    return t;
}

// ---- ADC: one block of 128 samples into BUF0, reader stopped after it ----
static int adc_block(void) {
    SPI(ADC_BUF0) = BUF0; SPI(ADC_BUF1) = BUF1; SPI(ADC_NSAMP) = 128;
    SPI(ADC_STATUS) = A_FULL0 | A_FULL1 | A_OVERRUN | A_BUSERR;
    SPI(ADC_CTRL) = A_MODE | A_RUN;
    uint32_t t = mcycle();
    while (!(SPI(ADC_STATUS) & A_FULL0)) if (mcycle() - t > TIMEOUT) { SPI(ADC_CTRL) = A_MODE; return 0; }
    SPI(ADC_CTRL) = A_MODE;                                // RUN = 0: stops after the current frame (into BUF1)
    t = mcycle();
    while (SPI(ADC_STATUS) & A_RUNNING) if (mcycle() - t > TIMEOUT) return 0;
    return 1;
}
static int32_t sx14(uint16_t s) { return (int32_t)((uint32_t)s << 18) >> 18; }

// ---- FFT on 128 samples at src: 14-bit, gain 2^2, band bins 32..39 (as ae_node.c). Returns STATUS, 0 on timeout.
static uint32_t fft_run(uint32_t src) {
    FFT(F_SETUP0) = 2u | (4u << 8);
    FFT(F_SETUP1) = 3u | (32u << 8) | (39u << 16);
    FFT(F_THRESH) = 179u | (192u << 8);
    FFT(F_SRC) = src;
    FFT(F_STATUS) = 0x46;
    FFT(F_CTRL) = 1u | 2u;
    uint32_t st, t = mcycle();
    while (!((st = FFT(F_STATUS)) & 2u)) if (mcycle() - t > TIMEOUT) return 0;
    return st;
}
static void fft_print(uint32_t st) {
    kv("fft status", st); kv("peak bin", FFT(F_PEAK_BIN)); kv("peak pow", FFT(F_PEAK_POW));
    kv("band energy", FFT(F_BAND)); kv("total energy", FFT(F_TOTAL)); kv("td energy", FFT(F_TD));
}
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
