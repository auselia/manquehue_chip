// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Benchmark: one 128-sample AE block, the AE-FFT accelerator (fft_hwpe) against the same algorithm in C on the
// CVE2 core of Croc. The software does exactly what the accelerator does, bit for bit (offset, gain, TD energy,
// Hann window, 64-point radix-2 DIF in place with halving, real-FFT fix-up, power, peak, band, total, flags), so
// both must give the registers of the golden model.  Cycles come from the mcycle counter of the core.
// The core has no multiplier (RV32MNone), so every product is a call of __mulsi3 in libgcc.

#include "uart.h"
#include "bench.h"

#define FFT_BASE 0x22001000u
#define REG(o)   (*(volatile uint32_t *)(FFT_BASE + (o)))

static uint32_t cyc(void) {
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static void kv(char k, uint32_t v) {            // "k=hex " (the cycle counts are converted to decimal offline)
    uart_write(k);
    uart_write('=');
    for (int i = 28; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]);
    uart_write(' ');
}

// a * b with b below 256: 40-bit result as {hi, lo}
static uint32_t mul32x8(uint32_t a, uint32_t b, uint32_t *hi) {
    uint32_t lo = 0, h = 0;
    for (int i = 0; i < 8; i++) {
        if ((b >> i) & 1) {
            uint32_t sl = a << i, sh = i ? a >> (32 - i) : 0, t = lo + sl;
            h += sh + (t < lo);
            lo = t;
        }
    }
    *hi = h;
    return lo;
}

// ---------------------------------------------------------------------------------------------
// software version of the accelerator
// ---------------------------------------------------------------------------------------------
static int sat;

static int32_t clip(int32_t v) {
    if (v > 32767) { sat = 1; return 32767; }
    if (v < -32768) { sat = 1; return -32768; }
    return v;
}

static int32_t rnd(int32_t v, int s) { return (v + (1 << (s - 1))) >> s; }

static int32_t cos_k(int k) { return k <= 32 ? cos_rom[k] : -cos_rom[64 - k]; }
static int32_t sin_k(int k) { return k <= 32 ? cos_rom[32 - k] : cos_rom[k - 32]; }

static int rev6(int a) {
    int r = 0;
    for (int i = 0; i < 6; i++) { r = (r << 1) | (a & 1); a >>= 1; }
    return r;
}

#ifndef ONLY_HW
struct feat { uint32_t peak, peak_pow, band, total, td; uint32_t status; };

static uint32_t t_win, t_fft, t_bin;

static void sw_fft(const uint32_t *cf, struct feat *o) {
    int16_t *x = (int16_t *)buf;                       // x[2m] = Re, x[2m+1] = Im of word m
    int gs = cf[0] & 15, es = (cf[0] >> 8) & 15, dc = (int16_t)(cf[0] >> 16);
    int kmin = cf[1] & 127, blo = (cf[1] >> 8) & 127, bhi = (cf[1] >> 16) & 127;
    uint32_t bthr = cf[2] & 255;
    uint32_t td = 0;
    sat = 0;

    for (int n = 0; n < 128; n++) {                    // pass 1: offset, gain, TD energy, window
        int32_t g = clip(((int32_t)x[n] - dc) << gs);
        td += (uint32_t)((g * g) >> 10);
        int c = cos_k(n <= 64 ? n : 128 - n);
        int32_t w = (32768 - c) >> 1;
        x[n] = (int16_t)rnd(g * w, 15) ;
    }
    uint32_t t1 = cyc();

    for (int s = 0; s < 6; s++) {                      // pass 2: six stages in place
        int half = 32 >> s;
        for (int n = 0; n < 32; n++) {
            int b = n & (half - 1);
            int lo = ((n & ~(half - 1)) << 1) | b;
            int up = lo + half;
            int k = b << (s + 1);
            int32_t c = cos_k(k), sn = sin_k(k);
            int32_t lr = x[2 * lo], li = x[2 * lo + 1], ur = x[2 * up], ui = x[2 * up + 1];
            int32_t sr = clip(rnd(lr + ur, 1)), si = clip(rnd(li + ui, 1));
            int32_t dr = clip(rnd(lr - ur, 1)), di = clip(rnd(li - ui, 1));
            int32_t pr = clip(rnd(c * dr + sn * di, 15));
            int32_t pi = clip(rnd(c * di - sn * dr, 15));
            x[2 * lo] = sr; x[2 * lo + 1] = si; x[2 * up] = pr; x[2 * up + 1] = pi;
        }
    }
    uint32_t t2 = cyc();

    uint32_t pk = 0, pkp = 0, tot = 0, band = 0;       // pass 3: bins
    int first = 1;
    for (int k = 0; k <= 64; k++) {
        int a = rev6(k & 63), y = rev6((64 - k) & 63);
        int32_t ar = x[2 * a], ai = x[2 * a + 1], yr = x[2 * y], yi = x[2 * y + 1];
        int32_t er = rnd(ar + yr, 1), ei = rnd(ai - yi, 1);
        int32_t dr = clip(rnd(ar - yr, 1)), di = clip(rnd(ai + yi, 1));
        int32_t or_ = di, oi = -dr;
        int32_t c = cos_k(k), sn = sin_k(k);
        int32_t xr = clip(er + rnd(c * or_ + sn * oi, 15));
        int32_t xi = clip(ei + rnd(c * oi - sn * or_, 15));
        uint32_t p = (uint32_t)(xr * xr + xi * xi) >> es;
        if (k >= kmin) {
            if (first || p > pkp) { pk = k; pkp = p; }
            first = 0;
            uint32_t t = tot + p;
            if (t < tot) { t = 0xFFFFFFFFu; sat = 1; }
            tot = t;
            if (k >= blo && k <= bhi) {
                t = band + p;
                if (t < band) { t = 0xFFFFFFFFu; sat = 1; }
                band = t;
            }
        }
    }
    uint32_t h, l;
    l = mul32x8(tot, bthr, &h);                          // band * 256 >= total * BAND_THR
    uint32_t bh = band >> 24, bl = band << 8;
    uint32_t band_ok = bh > h || (bh == h && bl >= l);
    uint32_t decay = 0;                                  // the first block of an event has no TD_PREV, so DECAY is 0
    o->peak = pk; o->peak_pow = pkp; o->band = band; o->total = tot; o->td = td;
    o->status = (sat << 2) | (1u << 3) | (band_ok << 4) | (decay << 5);
    t_win = t1; t_fft = t2; t_bin = cyc();
}

static int match(const struct feat *f, const uint32_t *e) {
    return f->peak == e[0] && f->peak_pow == e[1] && f->band == e[2] && f->total == e[3] && f->td == e[4] &&
           (f->status & 0x3C) == e[6];
}

#endif

int main() {
    uart_init();
    uint32_t c0, c1;
    uint32_t ok;
#ifndef ONLY_HW
    // ---- software on the CPU
    struct feat f;
    c0 = cyc();
    sw_fft(cfg0, &f);
    c1 = cyc();
    ok = match(&f, exp0);
    kv('T', c1 - c0);       // total
    kv('W', t_win - c0);    // window pass
    kv('F', t_fft - t_win); // FFT
    kv('B', t_bin - t_fft); // bins
    kv('S', ok);
#else
    // ---- the accelerator
    REG(0x18) = cfg0[0];
    REG(0x1C) = cfg0[1];
    REG(0x20) = cfg0[2];
    REG(0x08) = (uint32_t)buf;
    REG(0x10) = 0;
    REG(0x04) = 0x46;
    c0 = cyc();
    REG(0x00) = 1u | 2u;                       // START + CLR_PREV
    while (!(REG(0x04) & 2u)) {
    }
    c1 = cyc();
    uint32_t st = REG(0x04);
    ok = REG(0x24) == exp0[0] && REG(0x28) == exp0[1] && REG(0x2C) == exp0[2] &&
         REG(0x30) == exp0[3] && REG(0x34) == exp0[4] && (st & 0x3C) == exp0[6];
    kv('T', c1 - c0);       // total, start to done seen by the CPU
    kv('R', REG(0x3C));     // CYCLES register of the accelerator
    kv('S', ok);
#endif
    uart_write('\n');
    uart_write(ok ? 'P' : 'F');
    uart_write('\n');
    uart_write_flush();
    return !ok;
}
