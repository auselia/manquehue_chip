// Step 1, FFT standalone: a 128-sample tone at bin 36 in SRAM (no ADC), the FFT in place, PEAK_BIN must be 36.
#include "bringup.h"
int main() {
    uart_init();
    put("STEP1 fft\n");
    // y[n] = 2 cos(w) y[n-1] - y[n-2] in Q14, amplitude 3000 codes (as fft_lora.c, no multiplier needed)
    int32_t y0 = 0, y1 = 2942;
    volatile uint16_t *s = (volatile uint16_t *)BUF0;
    for (int n = 0; n < 128; n++) {
        s[n] = (uint16_t)(y0 & 0x3FFF);
        int32_t m = (y1 << 11) + (y1 << 10) + (y1 << 6) + (y1 << 5) + (y1 << 4) + (y1 << 3) + (y1 << 2);
        int32_t y2 = -(m >> 13) - y0;
        y0 = y1; y1 = y2;
    }
    uint32_t t = mcycle(), st = fft_run(BUF0);
    kv("cycles", mcycle() - t);
    fft_print(st);
    check(0, st != 0u, "fft timeout");
    check(1, !(st & (1u << 6)), "fft error");
    check(2, FFT(F_PEAK_BIN) == 36u, "peak bin");
    return finish("STEP1");
}
