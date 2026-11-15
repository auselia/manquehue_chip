// Step 5 (ADC + FFT) and, with -DLORA, step 6 (ADC + FFT + LoRa): NBLK blocks of 128 ADC samples, the FFT on each,
// features printed. Step 6 sends each block as the 24-byte packet of fft_lora.c / ae_node.c over LoRa.
// With -DEXPECT_BIN=b (simulation, +adc_tone=b) the peak bin must be b.
#include "bringup.h"
#ifndef NBLK
#define NBLK 5
#endif
#ifdef LORA
static uint8_t pkt[25];
#define NAME "STEP6"
#else
#define NAME "STEP5"
#endif
int main() {
    uart_init();
    put(NAME " adc fft\n");
#ifdef LORA
    uint8_t ver = rf_init(24);                             // the radio first: the ADC reader is stopped between blocks
    kv("radio version", ver);
    if (ver != 0x12) fail |= 1u;
#endif
    for (uint32_t b = 0; b < NBLK; b++) {
        if (!adc_block()) { fail |= 1u << 1; break; }
        uint32_t tag = *(volatile uint32_t *)BUF0, st = fft_run(BUF0);
        if (!st || (st & (1u << 6))) fail |= 1u << 2;
#ifdef LORA
        kv("peak bin", FFT(F_PEAK_BIN));                   // step 6: the full features go out in the packet
#else
        kv("block", b); fft_print(st);
#endif
#ifdef EXPECT_BIN
        if (FFT(F_PEAK_BIN) != EXPECT_BIN) fail |= 1u << 3;
#endif
#ifdef LORA
        pkt[0] = 0x80; pkt[1] = 'A'; pkt[2] = (uint8_t)b; pkt[3] = (uint8_t)FFT(F_PEAK_BIN);
        pkt[4] = (uint8_t)((st >> 2) & 0xFu); put32(&pkt[5], tag);
        put32(&pkt[9], FFT(F_PEAK_POW)); put32(&pkt[13], FFT(F_BAND));
        put32(&pkt[17], FFT(F_TOTAL)); put32(&pkt[21], FFT(F_TD));
        uint32_t a = rf_send(pkt, 24);
        kv("tx", a);
        if (!a) fail |= 1u << 4;
#else
        (void)tag;
#endif
    }
    if (SPI(ADC_STATUS) & A_BUSERR) fail |= 1u << 6;
    kv("adc count", SPI(ADC_COUNT));
#ifdef LORA
    if (SPI(RF_ERR) != 0u) fail |= 1u << 5;
#else
    check(1, !(fail & 2u), "adc block");
    check(2, !(fail & 4u), "fft");
    check(3, !(fail & 8u), "peak bin");
    check(6, !(fail & 64u), "adc bus error");
#endif
    return finish(NAME);
}
