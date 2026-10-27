// End-to-end sensor node from the QSPI flash: ADS7057 -> SRAM -> AE-FFT -> LoRa (SX1276).
// The ADC reader runs free at IDLE 2 (20 clocks per sample, the fastest setting) into two 128-sample buffers.
// For each block: wait for a full buffer, run the FFT on it in place, release the buffer, pack the features into a
// 24-byte packet and start the LoRa TX. The next block is processed while the radio is on the air, the packet is
// loaded only after TxDone (DIO0) of the previous one.
// While the FFT runs (about 29,000 clocks) the reader fills the other buffer in 2,560 clocks and then finds both
// buffers full: it sets OVERRUN and drops whole buffers. That is expected, the FFT keeps up with one block in 11.
//
// Testbench: tb_croc_soc with +adc_tone=36 (a tone at FFT bin 36) and +rf_airtime_ns (LoRa time on air of the
// packet). sim/sw/flash/check_ae_node.py checks every packet against the golden model of the FFT.
// The ADC and the radio share one SPI bus. Before each radio SPI access the firmware stops the reader (RUN = 0, wait
// until it is idle) and starts it again after. Waiting for TxDone reads an rf_spi register only, so the reader runs
// while the packet is on the air. ADC_STATUS.BUS_WAIT must stay 0.
// Packet (little endian): 0 'A', 1 sequence, 2 PEAK_BIN, 3 STATUS[5:2] (SAT, PREV_VALID, BAND_OK, DECAY),
// 4..7 first buffer word (samples 0 and 1, a test aid to find the block), 8 PEAK_POW, 12 BAND_ENERGY,
// 16 TOTAL_ENERGY, 20 TD_ENERGY.
// UART: one line per block, "B<seq> W<wait> F<fft> R<radio wait> L<load>" in clock cycles (hex), then
// "AE NODE OK" or "AE NODE FAIL <mask>".
#include <stdint.h>
#include "uart.h"

#ifndef TONE_BIN
#define TONE_BIN 36
#endif
#define NBLK 4

#define SPI_BASE  0x22000000u
#define FFT_BASE  0x22001000u
#define SPI(o)    (*(volatile uint32_t *)(SPI_BASE + (o)))
#define FFT(o)    (*(volatile uint32_t *)(FFT_BASE + (o)))

// radio master
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

// ADC reader
#define ADC_CTRL   0x100
#define ADC_STATUS 0x104
#define ADC_BUF0   0x108
#define ADC_BUF1   0x10C
#define ADC_NSAMP  0x110
#define A_EN       (1u << 0)
#define A_RUN      (1u << 1)
#define A_IDLE(n)  ((uint32_t)(n) << 8)
#define A_TRIG_LOW (1u << 14)
#define A_RUNNING  (1u << 0)
#define A_FULL0    (1u << 1)
#define A_FULL1    (1u << 2)
#define A_OVERRUN  (1u << 3)
#define A_BUSERR   (1u << 4)
#define A_BUSWAIT  (1u << 7)

// AE-FFT
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

// two buffers of 128 samples (256 B each) below the stack at the top of the 2 KB SRAM
#define BUF0 0x10000400u
#define BUF1 0x10000500u

#define TIMEOUT 40000000u                                  // clock cycles, about 2.2 s at 18.18 MHz

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

static void rf_reg(uint8_t a, uint8_t v) {
    uint8_t b[2] = {(uint8_t)(0x80u | a), v};
    rf_xfer(b, 0, 2);
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

// stop the ADC reader before a radio SPI access (shared bus), start it again after
static void adc_pause(void) {
    uint32_t t = mcycle();
    SPI(ADC_CTRL) = A_EN | A_TRIG_LOW | A_IDLE(2);
    while (SPI(ADC_STATUS) & A_RUNNING)
        if (mcycle() - t > TIMEOUT) { fail |= 1u << 6; break; }
}
static void adc_resume(void) { SPI(ADC_CTRL) = A_EN | A_RUN | A_TRIG_LOW | A_IDLE(2); }

static uint8_t pkt[25];                                    // 0x80 (FIFO write) + 24 payload bytes

int main() {
    uart_init();

    // radio: out of reset, SPI at clk / 4 (4.5 MHz, below the 10 MHz of the SX1276 with margin on the 50 ns
    // high and low times), LoRa, BW 125 kHz, CR 4/5, explicit header, SF7, CRC on
    SPI(RF_PINS) = 1u;
    SPI(RF_CTRL) = 1u | (1u << 8) | (1u << 16);
    rf_reg(0x01, 0x80);                                    // RegOpMode: LoRa, sleep
    rf_reg(0x01, 0x81);                                    // LoRa, standby
    rf_reg(0x1D, 0x72);                                    // RegModemConfig1
    rf_reg(0x1E, 0x74);                                    // RegModemConfig2
    rf_reg(0x0E, 0x80);                                    // RegFifoTxBaseAddr
    rf_reg(0x22, 24);                                      // RegPayloadLength

    // FFT: 14-bit samples, gain 2^2 (full scale without clipping), band = bins 32..39 (227 to 277 kHz at 909 kS/s)
    FFT(F_SETUP0) = 2u | (4u << 8);
    FFT(F_SETUP1) = 3u | (32u << 8) | (39u << 16);
    FFT(F_THRESH) = 179u | (192u << 8);

    // ADC: free running, IDLE 2 (909 kS/s at 18.18 MHz)
    SPI(ADC_BUF0)  = BUF0;
    SPI(ADC_BUF1)  = BUF1;
    SPI(ADC_NSAMP) = 128;
    SPI(ADC_CTRL)  = A_EN | A_RUN | A_TRIG_LOW | A_IDLE(2);

    for (uint32_t seq = 0; seq < NBLK; seq++) {
        uint32_t t0 = mcycle(), st;
        while (!((st = SPI(ADC_STATUS)) & (A_FULL0 | A_FULL1)))
            if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 0; break; }
        uint32_t full = (st & A_FULL0) ? A_FULL0 : A_FULL1;
        uint32_t buf  = (full == A_FULL0) ? BUF0 : BUF1;
        uint32_t tag  = *(volatile uint32_t *)buf;
        uint32_t t1 = mcycle();

        FFT(F_SRC) = buf;
        FFT(F_STATUS) = 0x46;                              // clear DONE, SAT, ERROR
        FFT(F_CTRL) = 1u | (seq == 0 ? 2u : 0u);           // START, CLR_PREV on the first block
        while (!((st = FFT(F_STATUS)) & 2u))
            if (mcycle() - t1 > TIMEOUT) { fail |= 1u << 1; break; }
        if (st & (1u << 6)) fail |= 1u << 1;
        uint32_t t2 = mcycle();
        uint32_t peak = FFT(F_PEAK_BIN);
        put32(&pkt[9],  FFT(F_PEAK_POW));
        put32(&pkt[13], FFT(F_BAND));
        put32(&pkt[17], FFT(F_TOTAL));
        put32(&pkt[21], FFT(F_TD));
        SPI(ADC_STATUS) = full;                            // release the buffer to the reader
        if (peak != TONE_BIN) fail |= 1u << 3;
        pkt[0] = 0x80;                                     // FIFO write
        pkt[1] = 'A';
        pkt[2] = (uint8_t)seq;
        pkt[3] = (uint8_t)peak;
        pkt[4] = (uint8_t)((st >> 2) & 0xFu);
        put32(&pkt[5], tag);

        // previous packet still on the air: wait for TxDone, clear it in the radio and in rf_spi
        if (seq > 0) {
            while (!(SPI(RF_IRQ_ST) & IRQ_DIO0))
                if (mcycle() - t2 > TIMEOUT) { fail |= 1u << 2; break; }
        }
        uint32_t t3 = mcycle();
        adc_pause();
        if (seq > 0) {
            rf_reg(0x12, 0x08);
            SPI(RF_IRQ_ST) = IRQ_DIO0;
        }
        rf_reg(0x0D, 0x80);                                // FifoAddrPtr = TX base
        rf_xfer(pkt, 0, 25);
        rf_reg(0x01, 0x83);                                // LoRa, TX
        adc_resume();
        uint32_t t4 = mcycle();

        put("B"); put_hex(seq); put(" W"); put_hex(t1 - t0); put(" F"); put_hex(t2 - t1);
        put(" R"); put_hex(t3 - t2); put(" L"); put_hex(t4 - t3); put("\n");
    }

    uint32_t t5 = mcycle();
    while (!(SPI(RF_IRQ_ST) & IRQ_DIO0))
        if (mcycle() - t5 > TIMEOUT) { fail |= 1u << 2; break; }
    adc_pause();                                           // RUN = 0, and the bus is free for the last radio access
    rf_reg(0x12, 0x08);
    SPI(RF_IRQ_ST) = IRQ_DIO0;

    uint32_t st = SPI(ADC_STATUS);
    if (st & A_BUSERR) fail |= 1u << 4;
    if (st & A_BUSWAIT) fail |= 1u << 7;                   // an ADC frame waited for the radio
    if (SPI(RF_ERR) != 0u) fail |= 1u << 5;
    put("ADC status "); put_hex(st); put("\n");

    if (fail) { put("AE NODE FAIL "); put_hex(fail); put("\n"); }
    else put("AE NODE OK\n");
    uart_write_flush();
    return (int)fail;
}
