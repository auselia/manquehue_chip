// Cavitation detector from the QSPI flash: ADS7057 triggered capture -> AE-FFT on two blocks -> LoRa packet.
// The ADC reader runs in triggered mode at IDLE 2 (909 kS/s at 18.18 MHz). WAKE_N (the listener of the AFE board)
// completes the buffer being written (T, holds the trigger) and stops the reader. The other buffer (P) holds the 128
// samples before T. FFT run 1 on T (CLR_PREV) gives the spectrum features and BAND_OK, FFT run 2 on P compares the
// time-domain energy: DECAY is set when P has less than DECAY_THR/256 of the energy of T. Possible cavitation =
// BAND_OK of run 1 and DECAY of run 2 (doc/spec_fft.tex of the AFE project: a burst in the band that stands out
// from the signal around it; a steady 254 kHz tone passes BAND_OK and fails DECAY).
// FFT setup for 909 kS/s (7.1 kHz per bin): KMIN 6 (42.6 kHz), band bins 22..55 (156 to 391 kHz), BAND_THR 179
// (0.70), DECAY_THR 192 (0.75), GAIN_SHIFT 3, EN_SHIFT 4. These are the spec values at 2.5 MS/s moved to 909 kS/s.
// Packet, 24 bytes, little endian: 0 'C', 1 sequence, 2 flags ([0] BAND_OK [1] DECAY [2] SAT [3] BIG_N seen),
// 3 PEAK_BIN, 4 PEAK_POW, 8 BAND_ENERGY, 12 TOTAL_ENERGY, 16 TD_ENERGY of T, 20 TD_ENERGY of P.
// UART: "T<buf> W<first word of T> P<first word of P>" (test aid for sim/sw/flash/check_ae_cav.py), the features,
// then "CAVITATION YES" or "CAVITATION NO", then "AE CAV DONE" (or "AE CAV FAIL <mask>" on a timeout or error).
#include <stdint.h>
#include "uart.h"

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
#define ST_TX_FULL  (1u << 2)
#define ST_RX_EMPTY (1u << 3)
#define IRQ_DONE    (1u << 0)
#define IRQ_DIO0    (1u << 4)

#define ADC_CTRL   0x100
#define ADC_STATUS 0x104
#define ADC_BUF0   0x108
#define ADC_BUF1   0x10C
#define ADC_NSAMP  0x110
#define ADC_PINS   0x120
#define A_EN        (1u << 0)
#define A_RUN       (1u << 1)
#define A_TRIGGERED (1u << 2)
#define A_IDLE(n)   ((uint32_t)(n) << 8)
#define A_TRIG_LOW  (1u << 14)
#define A_DONE      (1u << 5)
#define A_BUSERR    (1u << 4)
#define A_ACTIVE    (1u << 8)

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

#define BUF0 0x10000400u
#define BUF1 0x10000500u
#define TIMEOUT 40000000u

static uint32_t fail;

static uint32_t mcycle(void) {
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static void put(const char *s) {
    while (*s) uart_write(*s++);
}

static void put_hex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]);
}

static void rf_xfer(const uint8_t *tx, uint32_t n) {
    uint32_t i = 0, j = 0, t0 = mcycle();
    SPI(RF_CMD) = n;
    while (j < n) {
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 2; return; }
        uint32_t st = SPI(RF_STATUS);
        if (i < n && !(st & ST_TX_FULL)) SPI(RF_DATA) = tx[i++];
        else if (!(st & ST_RX_EMPTY)) { (void)SPI(RF_DATA); j++; }
    }
    while (!(SPI(RF_IRQ_ST) & IRQ_DONE))
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 2; return; }
    SPI(RF_IRQ_ST) = IRQ_DONE;
}

static void rf_reg(uint8_t a, uint8_t v) {
    uint8_t b[2] = {(uint8_t)(0x80u | a), v};
    rf_xfer(b, 2);
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

// one FFT run on the buffer at addr, returns STATUS
static uint32_t fft_run(uint32_t addr, uint32_t clr_prev) {
    FFT(F_SRC) = addr;
    FFT(F_STATUS) = 0x46;
    FFT(F_CTRL) = 1u | (clr_prev ? 2u : 0u);
    uint32_t st, t0 = mcycle();
    while (!((st = FFT(F_STATUS)) & 2u))
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 1; break; }
    if (st & (1u << 6)) fail |= 1u << 1;
    return st;
}

static uint8_t pkt[25];

int main() {
    uart_init();

    SPI(RF_PINS) = 1u;
    SPI(RF_CTRL) = 1u | (1u << 8) | (1u << 16);
    rf_reg(0x01, 0x80);                                    // LoRa, sleep
    rf_reg(0x01, 0x81);                                    // LoRa, standby
    rf_reg(0x1D, 0x72);                                    // BW 125 kHz, CR 4/5, explicit header
    rf_reg(0x1E, 0x74);                                    // SF7, CRC on
    rf_reg(0x0E, 0x80);
    rf_reg(0x22, 24);

    FFT(F_SETUP0) = 3u | (4u << 8);
    FFT(F_SETUP1) = 6u | (22u << 8) | (55u << 16);
    FFT(F_THRESH) = 179u | (192u << 8);

    SPI(ADC_BUF0)  = BUF0;
    SPI(ADC_BUF1)  = BUF1;
    SPI(ADC_NSAMP) = 128;
    SPI(ADC_CTRL)  = A_EN | A_RUN | A_TRIGGERED | A_TRIG_LOW | A_IDLE(2);

    uint32_t st, t0 = mcycle(), big = 0;
    while (!((st = SPI(ADC_STATUS)) & A_DONE)) {
        if (!(SPI(ADC_PINS) & (1u << 9))) big = 1;          // BIG_N low (not latched on the v3 board)
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 0; break; }
    }
    if (st & A_BUSERR) fail |= 1u << 4;
    uint32_t tb  = (st & A_ACTIVE) ? 0u : 1u;              // the trigger buffer is the one not marked active
    uint32_t bt  = tb ? BUF1 : BUF0, bp = tb ? BUF0 : BUF1;
    put("T"); put_hex(tb); put(" W"); put_hex(*(volatile uint32_t *)bt); put(" P"); put_hex(*(volatile uint32_t *)bp);
    put("\n");

    uint32_t s1 = fft_run(bt, 1);
    uint32_t peak = FFT(F_PEAK_BIN), ppow = FFT(F_PEAK_POW), band = FFT(F_BAND), total = FFT(F_TOTAL), td1 = FFT(F_TD);
    uint32_t s2 = fft_run(bp, 0);
    uint32_t td2 = FFT(F_TD);
    uint32_t band_ok = (s1 >> 4) & 1u, decay = (s2 >> 5) & 1u, sat = ((s1 | s2) >> 2) & 1u;

    pkt[0] = 0x80;                                         // FIFO write
    pkt[1] = 'C';
    pkt[2] = 0;
    pkt[3] = (uint8_t)(band_ok | (decay << 1) | (sat << 2) | (big << 3));
    pkt[4] = (uint8_t)peak;
    put32(&pkt[5], ppow); put32(&pkt[9], band); put32(&pkt[13], total); put32(&pkt[17], td1); put32(&pkt[21], td2);
    rf_reg(0x0D, 0x80);
    rf_xfer(pkt, 25);
    rf_reg(0x01, 0x83);                                    // TX
    t0 = mcycle();
    while (!(SPI(RF_IRQ_ST) & IRQ_DIO0))
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 2; break; }
    rf_reg(0x12, 0x08);
    SPI(RF_IRQ_ST) = IRQ_DIO0;

    put("peak "); put_hex(peak); put(" band "); put_hex(band); put(" total "); put_hex(total);
    put(" tdT "); put_hex(td1); put(" tdP "); put_hex(td2); put("\n");
    put(band_ok && decay ? "CAVITATION YES\n" : "CAVITATION NO\n");
    if (fail) { put("AE CAV FAIL "); put_hex(fail); put("\n"); }
    else put("AE CAV DONE\n");
    uart_write_flush();
    return (int)fail;
}
