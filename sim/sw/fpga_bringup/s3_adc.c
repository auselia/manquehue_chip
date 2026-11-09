// Step 3, ADC standalone (AFE v1 board on Pmod JD): 128 samples into SRAM, printed with min, max and mean.
// Checks: the block completes, no bus error or overrun, every sample is a sign-extended 14-bit code, and the codes
// are not all the same (a stuck SDO reads all 0 with the pull-down). With -DRAMP (simulation, tb_croc_soc ADS7057
// model) the samples must also step by 1237 mod 2^14.
// LD4 shows WAKE_N, LD5 BIG_N: touch or drive the AFE input to see them.
// -DDUMP=n: then n blocks of 128 samples printed in full, for adc_fit.py (sine fit) on the Mac.
#include "bringup.h"
int main() {
    uart_init();
    put("STEP3 adc\n");
    check(0, adc_block(), "no full block");
    uint32_t st = SPI(ADC_STATUS);
    kv("adc status", st); kv("adc count", SPI(ADC_COUNT));
    check(1, !(st & A_BUSERR), "bus error");
    volatile uint16_t *s = (volatile uint16_t *)BUF0;
    int32_t mn = 8191, mx = -8192, sum = 0;
    for (int i = 0; i < 128; i++) {
        uint16_t v = s[i], top = v >> 13;
        if (top != 0u && top != 7u) fail |= 1u << 2;
        int32_t x = sx14(v);
        if (x < mn) mn = x;
        if (x > mx) mx = x;
        sum += x;
#ifdef RAMP
        if (i && ((uint16_t)(v - s[i - 1]) & 0x3FFFu) != 1237u) fail |= 1u << 4;
#endif
        if (i < 16) { put_hex(v); put((i & 7) == 7 ? "\n" : " "); }
    }
    kv("min", (uint32_t)mn); kv("max", (uint32_t)mx); kv("mean", (uint32_t)(sum >> 7));
    check(2, !(fail & (1u << 2)), "sample format");
    check(3, mx != mn, "all samples equal");
#ifdef RAMP
    check(4, !(fail & (1u << 4)), "ramp");
#endif
#ifdef DUMP
    // -DDUMP=n: n more blocks, all 128 samples of each in hex (sign-extended 14-bit codes, 1.000 MSPS: 20 clocks per
    // frame at 20 MHz), for adc_fit.py on the Mac. "cycles" is the time of adc_block, start to stop.
    for (int b = 0; b < DUMP; b++) {
        uint32_t t0 = mcycle();
        int ok = adc_block();
        uint32_t dt = mcycle() - t0;
        if (!ok) { check(5, 0, "dump block"); break; }
        kv("block", (uint32_t)b); kv("cycles", dt);
        for (int i = 0; i < 128; i++) { put_hex(s[i]); put((i & 7) == 7 ? "\n" : " "); }
    }
    put("dump end\n");
#endif
    return finish("STEP3");
}
