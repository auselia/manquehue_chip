// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// System test of the AE-FFT accelerator (fft_hwpe) in the user domain.
// The program feeds a recorded AE event block from its own read-only data (so the accelerator reads
// the samples straight out of the SRAM), then the same block halved (the second one must show DECAY), waits for the interrupt line in mip, and compares every
// result register and a checksum of the 65-bin dump with the Python golden model.
// Fits the 2 KB SRAM.  Build: ./build.sh   Run: scripts/sim/run_verilator.sh sim/sw/aefft_test/bin/aefft_test.hex

#include "uart.h"
#include "vectors.h"

#define FFT_BASE 0x22001000u
#define REG(o)   (*(volatile uint32_t *)(FFT_BASE + (o)))
#define IRQ_MIP  (1u << 22)          // user irq line 2 -> fast interrupt 4 + 2 -> mip bit 16 + 6

static uint32_t work[64];     // copy of block 0, then the halved block 1

static void put(const char *s) {
    while (*s) uart_write(*s++);
}

static void put_hex(uint32_t v) {
    for (int i = 12; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]);
}

static uint32_t mip(void) {
    uint32_t v;
    __asm__ volatile("csrr %0, mip" : "=r"(v));
    return v;
}

// bit n of fails is set when check n failed: 0 CONFIG, 1 irq timeout, 2 busy, 3 done, 4 error, 5 flags,
// 6 peak_bin, 7 peak_pow, 8 band, 9 total, 10 td, 11 td_prev, 12 irq not cleared, 13 spectrum checksum
static uint32_t fails;

static void check(int n, uint32_t got, uint32_t exp) {
    if (got != exp) fails |= 1u << n;
}
int main() {
    uart_init();
    check(0, REG(0x14), 0x02001007u);

    for (int b = 0; b < NBLK; b++) {
        REG(0x18) = cfg[b][0];
        REG(0x1C) = cfg[b][1];
        REG(0x20) = cfg[b][2];
        if (b == 0) {                           // the run overwrites blk0: keep a copy for block 1
            for (int i = 0; i < 64; i++) work[i] = blk0[i];
        } else {                                // block 1: every sample of block 0 halved
            for (int i = 0; i < 64; i++) {
                uint32_t w = work[i];
                int32_t lo = (int16_t)w >> 1, hi = (int16_t)(w >> 16) >> 1;
                work[i] = (uint32_t)(lo & 0xFFFF) | ((uint32_t)hi << 16);
            }
        }
        REG(0x08) = (b == 0) ? (uint32_t)blk0 : (uint32_t)work;
        REG(0x10) = 1;                          // interrupt on done
        REG(0x04) = 0x46;                       // clear DONE, SAT, ERROR
        REG(0x00) = 1u | (cfg[b][3] & 2u);      // START (+ CLR_PREV on the first block)

        uint32_t t = 0;
        while (!(mip() & IRQ_MIP) && ++t < 100000) {
        }
        check(1, t < 100000, 1);

        uint32_t st = REG(0x04);
        check(2, st & 1, 0);
        check(3, (st >> 1) & 1, 1);
        check(4, (st >> 6) & 1, 0);
        check(5, st & 0x3C, expf[b][6]);
        check(6, REG(0x24), expf[b][0]);
        check(7, REG(0x28), expf[b][1]);
        check(8, REG(0x2C), expf[b][2]);
        check(9, REG(0x30), expf[b][3]);
        check(10, REG(0x34), expf[b][4]);
        check(11, REG(0x38), expf[b][5]);
        REG(0x04) = 0x06;                       // clear DONE and SAT
        check(12, (mip() & IRQ_MIP) != 0, 0);
        if (b == 0) {
            uint32_t sum = 0;
            volatile uint32_t *z = (volatile uint32_t *)blk0;
            for (int i = 0; i < 64; i++) sum += z[i];
            check(13, sum, Z_SUM);
        }
    }

    if (fails) {
        put("AEFFT FAIL ");
        put_hex(fails);
        uart_write('\n');
    } else {
        put("AEFFT PASS\n");
    }
    uart_write_flush();
    return fails != 0;
}
