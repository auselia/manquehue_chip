// Step 7, event capture and features (AFE v1 on JD), from the QSPI flash. NEV times: the ADC reader waits for
// WAKE_N (triggered mode), keeps 64 samples before the trigger and 448 after it (a 512-sample ring in two 256-sample
// buffers, 1.000 MSPS: 64 us before, 448 us after). It arms only after 200 us with no WAKE_N edge. Per event croc computes:
//   - FFT features of the 4 blocks of 128 samples in time order: peak bin, STATUS (BAND_OK bit 4, DECAY bit 5),
//     band, total and time-domain energy. The previous-block energy is cleared before block 0 only, so DECAY
//     compares each block with the one before it.
//   - envelope features from the samples, integer only (croc has no multiplier): DC = mean of the 64 samples before
//     the trigger, a = |x - DC|, env = sum of the last 8 values of a (8 us). Peak of env and its time, rise (env
//     crosses 10 % to 90 % of its peak), fall (the last 90 % crossing to the first value under 10 % after it, 0xFFFF
//     if it stays over 10 % to the end), duration (samples with env at or over 50 %), onset (10 % crossing minus the
//     trigger index), peak |x - DC|, mean of a over rise to fall, crest = 16 x peak / mean.
// Prints the features, then the 512 samples in time order (4 hex digits, two's complement 14 bit), for event_check.py.
// Times are in samples = us. With -DNEV=n the number of events (default 4).
#include "bringup.h"

#ifndef NEV
#define NEV 4
#endif
#define NS   256u                                          // samples per buffer, the ring is 2 x NS
#define POST 448u                                          // samples kept after the trigger
#define PRE  (2u * NS - POST)                              // 64 samples before the trigger
#define ENVN 8u                                            // envelope window, a power of 2
// triggered mode of the ADC reader (rtl/user_domain/spi/adc_rdr.sv)
#define ADC_TRIG   0x124
#define ADC_TPOS   0x128
#define A_TRIG     (1u << 2)                               // CTRL TRIGGERED
#define A_DONE     (1u << 5)                               // STATUS DONE
#define A_WAKE     (1u << 6)                               // STATUS WAKE (sticky, W1C)
#define QUIET      (CLK_HZ / 5000u)                        // 200 us without a WAKE_N edge before arming

static uint16_t ring[2 * NS] __attribute__((aligned(4)));
static uint16_t blk[128] __attribute__((aligned(4)));      // FFT works in place: one block copied here

// no C library and no divider on croc: memset (the compiler calls it for array clears) and a shift-subtract division
void *memset(void *d, int c, unsigned n) { uint8_t *p = d; while (n--) *p++ = (uint8_t)c; return d; }
static uint32_t udiv(uint32_t n, uint32_t d) {
    uint32_t q = 0, r = 0;
    for (int i = 31; i >= 0; i--) { r = (r << 1) | ((n >> i) & 1u); if (r >= d) { r -= d; q |= 1u << i; } }
    return q;
}

static int32_t smp(uint32_t i, uint32_t first) { return sx14(ring[(first + i) & (2u * NS - 1u)]); }
static void put_hex4(uint32_t v) { for (int i = 12; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]); }

// one triggered capture: 1 when DONE came and the ring was full before the trigger, first = index of the oldest sample
static int capture(uint32_t *first, uint32_t *count) {
    SPI(ADC_CTRL) = A_MODE;                                // stop
    // Arm only after QUIET with no WAKE_N edge (sticky STATUS WAKE flag), so a capture starts at an event onset and
    // not on WAKE_N toggling in the decay of the event before (seen as a partial first event, 9 Nov 2026). With a
    // signal that never goes quiet it arms after TIMEOUT anyway.
    uint32_t t0 = mcycle();
    do { SPI(ADC_STATUS) = A_WAKE; wait_cycles(QUIET); } while ((SPI(ADC_STATUS) & A_WAKE) && mcycle() - t0 < TIMEOUT);
    SPI(ADC_BUF0) = (uint32_t)&ring[0]; SPI(ADC_BUF1) = (uint32_t)&ring[NS]; SPI(ADC_NSAMP) = NS;
    SPI(ADC_TRIG) = POST;
    SPI(ADC_STATUS) = 0xFFu;
    SPI(ADC_CTRL) = A_MODE | A_RUN | A_TRIG;
    uint32_t t = mcycle();
    while (!(SPI(ADC_STATUS) & A_DONE)) if (mcycle() - t > 2u * TIMEOUT) { SPI(ADC_CTRL) = A_MODE; return 0; }
    uint32_t tp = SPI(ADC_TPOS);
    *count = SPI(ADC_COUNT);
    *first = ((tp & 0xFFFu) + 2u * NS - PRE) & (2u * NS - 1u);
    return (tp >> 16) & 1u;
}

int main() {
    uart_init();
    put("STEP7 event\n");
    uint32_t got = 0;
    for (uint32_t e = 0; e < NEV; e++) {
        uint32_t first, count, tries = 0;
        int ok;
        // A trigger less than PRE samples after arming leaves samples of the capture before in the ring (COUNT < 512,
        // seen as onset -63 on 9 Nov 2026): that capture is taken again.
        while ((ok = capture(&first, &count)) && count < 2u * NS && ++tries < 8u) {}
        if (!ok || count < 2u * NS) { check(0, 0, "no trigger"); break; }
        got++;
        kv("event", e); kv("count", count);
        // FFT of the 4 blocks in time order
        for (uint32_t b = 0; b < 4u; b++) {
            for (uint32_t i = 0; i < 128u; i++) blk[i] = ring[(first + 128u * b + i) & (2u * NS - 1u)];
            FFT(F_SETUP0) = 2u | (4u << 8);
            FFT(F_SETUP1) = 3u | (32u << 8) | (39u << 16);
            FFT(F_THRESH) = 179u | (192u << 8);
            FFT(F_SRC) = (uint32_t)blk;
            FFT(F_STATUS) = 0x46;
            FFT(F_CTRL) = b == 0u ? (1u | 2u) : 1u;        // clear the previous-block energy before block 0 only
            uint32_t st, t = mcycle();
            while (!((st = FFT(F_STATUS)) & 2u)) if (mcycle() - t > TIMEOUT) { st = 0; break; }
            put("fft "); put_hex(b); put(" "); put_hex(st); put(" "); put_hex(FFT(F_PEAK_BIN)); put(" ");
            put_hex(FFT(F_BAND)); put(" "); put_hex(FFT(F_TOTAL)); put(" "); put_hex(FFT(F_TD)); put("\n");
        }
        // envelope
        int32_t dc = 0;
        for (uint32_t i = 0; i < PRE; i++) dc += smp(i, first);
        dc >>= 6;                                          // PRE = 64
        uint32_t win[ENVN] = {0}, sum = 0, emax = 0, imax = 0, pk = 0;
        // pass 1: peak of env and of |x - dc|
        for (uint32_t i = 0; i < 2u * NS; i++) {
            int32_t d = smp(i, first) - dc;
            uint32_t a = (uint32_t)(d < 0 ? -d : d);
            if (a > pk) pk = a;
            sum += a - win[i & (ENVN - 1u)]; win[i & (ENVN - 1u)] = a;
            if (sum > emax) { emax = sum; imax = i; }
        }
        // thresholds without a multiply: env * 10 against emax, 9 x emax, 5 x emax
        uint32_t e9 = (emax << 3) + emax, e1 = emax, e5 = (emax << 2) + emax;
        uint32_t r10 = 0xFFFF, r90 = 0xFFFF, f90 = 0xFFFF, f10 = 0xFFFF, dur = 0;
        uint32_t asum = 0, an = 0;
        for (uint32_t i = 0; i < ENVN; i++) win[i] = 0;
        sum = 0;
        for (uint32_t i = 0; i < 2u * NS; i++) {
            int32_t d = smp(i, first) - dc;
            uint32_t a = (uint32_t)(d < 0 ? -d : d);
            sum += a - win[i & (ENVN - 1u)]; win[i & (ENVN - 1u)] = a;
            uint32_t s10 = (sum << 3) + (sum << 1);
            if (r10 == 0xFFFF && s10 >= e1) r10 = i;
            if (r10 != 0xFFFF && r90 == 0xFFFF && s10 >= e9) r90 = i;
            if (i >= imax && s10 >= e9) { f90 = i; f10 = 0xFFFF; }
            if (f90 != 0xFFFF && f10 == 0xFFFF && i > f90 && s10 < e1) f10 = i;
            if (s10 >= e5) dur++;
            if (r10 != 0xFFFF && f10 == 0xFFFF) { asum += a; an++; }
        }
        uint32_t mean = an ? udiv(asum, an) : 0;
        kv("dc", (uint32_t)dc); kv("env peak", emax); kv("env peak at", imax);
        kv("rise", r90 - r10); kv("fall", f10 == 0xFFFF ? 0xFFFF : f10 - f90);
        kv("duration", dur); kv("onset", r10 - PRE);
        kv("peak", pk); kv("mean", mean); kv("crest x16", mean ? udiv(pk << 4, mean) : 0);
        put("samples\n");
        for (uint32_t i = 0; i < 2u * NS; i++) { put_hex4(ring[(first + i) & (2u * NS - 1u)]); put((i & 15u) == 15u ? "\n" : " "); }
        put("event end\n");
    }
    check(1, got == NEV, "events");
    return finish("STEP7");
}
