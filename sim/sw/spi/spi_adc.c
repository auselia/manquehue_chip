// ADC capture test from the CPU (fits the 2 KB SRAM). The SoC testbench (rtl/test/tb_croc_soc.sv) puts the ADS7057
// model on the ADC pins and feeds it (1237 * k + 5000) mod 16384 at CS fall k, so two consecutive samples differ by
// 1237 mod 2^14. The reader writes two buffers of 32 samples into the SRAM through the manager port.
// Prints "SPI ADC OK" and returns 0, or prints "SPI ADC FAIL" and returns a bit mask of the failed checks.
#include <stdint.h>
#include "uart.h"

#define SPI_BASE   0x22000000u
#define REG32(off) (*(volatile uint32_t *)(SPI_BASE + (off)))

#define ADC_CTRL   0x100
#define ADC_STATUS 0x104
#define ADC_BUF0   0x108
#define ADC_BUF1   0x10C
#define ADC_NSAMP  0x110
#define ADC_COUNT  0x11C

#define CTRL_EN       (1u << 0)
#define CTRL_RUN      (1u << 1)
#define CTRL_IDLE(n)  ((uint32_t)(n) << 8)
#define CTRL_TRIG_LOW (1u << 14)
#define ST_RUNNING    (1u << 0)
#define ST_FULL0      (1u << 1)
#define ST_FULL1      (1u << 2)
#define ST_OVERRUN    (1u << 3)
#define ST_BUSERR     (1u << 4)

#define NSAMP 32
// above the program (about 0.8 KB) and below the stack at the top of the 2 KB SRAM
#define BUF0 0x10000600u
#define BUF1 0x10000640u

static void puts_uart(const char *s) {
    for (int i = 0; s[i]; i++) uart_write(s[i]);
}

// wait until ADC_STATUS has all bits of mask set, at most about 200,000 polls
static int wait_status(uint32_t mask) {
    for (uint32_t t = 0; t < 200000u; t++)
        if ((REG32(ADC_STATUS) & mask) == mask) return 1;
    return 0;
}

static int sample_ok(uint16_t s) {
    uint16_t top = s >> 13;                                  // bits 15:13 are the sign extension of bit 13
    return top == 0u || top == 7u;
}

// the n samples at p follow each other, and follow `prev` when have_prev is set
static int run_ok(const volatile uint16_t *p, int n, uint16_t prev, int have_prev) {
    for (int i = 0; i < n; i++) {
        if (!sample_ok(p[i])) return 0;
        if ((i > 0 || have_prev) && (((uint16_t)(p[i] - (i ? p[i - 1] : prev))) & 0x3FFFu) != 1237u) return 0;
    }
    return 1;
}

int main() {
    uint32_t fail = 0;
    const volatile uint16_t *b0 = (const volatile uint16_t *)BUF0;
    const volatile uint16_t *b1 = (const volatile uint16_t *)BUF1;
    uart_init();

    REG32(ADC_BUF0)  = BUF0;
    REG32(ADC_BUF1)  = BUF1;
    REG32(ADC_NSAMP) = NSAMP;
    REG32(ADC_CTRL)  = CTRL_EN | CTRL_RUN | CTRL_TRIG_LOW | CTRL_IDLE(3);

    if (!wait_status(ST_FULL0)) fail |= 1u << 0;
    if (!run_ok(b0, NSAMP, 0, 0)) fail |= 1u << 1;
    if (!wait_status(ST_FULL1)) fail |= 1u << 2;
    if (!run_ok(b1, NSAMP, b0[NSAMP - 1], 1)) fail |= 1u << 3;

    REG32(ADC_CTRL) = CTRL_EN | CTRL_TRIG_LOW | CTRL_IDLE(3);   // RUN = 0: stop after the current frame
    for (uint32_t t = 0; t < 10000u && (REG32(ADC_STATUS) & ST_RUNNING); t++) { }
    uint32_t st = REG32(ADC_STATUS);
    if (st & ST_RUNNING) fail |= 1u << 4;
    if (st & ST_BUSERR)  fail |= 1u << 5;
    if (REG32(ADC_COUNT) < 2u * NSAMP) fail |= 1u << 6;
    REG32(ADC_CTRL) = CTRL_TRIG_LOW | CTRL_IDLE(3);             // EN = 0

    puts_uart(fail ? "SPI ADC FAIL\n" : "SPI ADC OK\n");
    uart_write_flush();
    return (int)fail;
}
