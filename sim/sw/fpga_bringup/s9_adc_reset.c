// Step 9, ADC reader after a JTAG reset (debug-module ndmreset), from the SRAM. Run it twice with a reset between:
//   run 1: arms a triggered capture (no WAKE_N comes) and waits in a loop for the reset. A cookie in the SRAM marks it.
//   reset: OpenOCD "reset halt" on the board, or tb_croc_soc +ndmreset_ns=<t> +binary2=<this hex> in simulation.
//   run 2: the same program loaded again finds the cookie: the reader must be idle (CTRL RUN 0, STATUS not running,
//          COUNT 0), then a block of 128 samples must complete with no overrun or bus error.
// Before the fix the user domain did not reset on ndmreset: the reader stayed in the capture with its OBI write lost
// (STATUS 0x08, COUNT 0xFFFF, all samples 0 on the ZedBoard, 9 Nov 2026).
// With -DRAMP (simulation, tb_croc_soc ADS7057 model) the samples must also step by 1237 mod 2^14.
// FAIL bits: 0 reader not idle after the reset, 1 no full block, 2 overrun or bus error, 3 samples all equal, 4 ramp.
#include "bringup.h"
#define COOKIE (*(volatile uint32_t *)0x1000063Cu)          // the word below BUF0: not in the image, not the stack
#define ARMED  0xAD0C0DE5u
#define A_TRIG (1u << 2)
#define ADC_TRIG 0x124
int main() {
    uart_init();
    if (COOKIE != ARMED) {
        COOKIE = ARMED;
        // arm first, print after: a reset that comes during the print still finds the reader in the capture
        SPI(ADC_BUF0) = BUF0; SPI(ADC_BUF1) = BUF0 + 128u; SPI(ADC_NSAMP) = 64;
        SPI(ADC_TRIG) = 32;
        SPI(ADC_STATUS) = 0xFFu;
        SPI(ADC_CTRL) = A_MODE | A_RUN | A_TRIG;
        put("STEP9 adc reset: run 1, armed, wait for the reset\n");
        for (;;) {}
    }
    COOKIE = 0;
    put("STEP9 adc reset: run 2, after the reset\n");
    uint32_t ctrl = SPI(ADC_CTRL), st = SPI(ADC_STATUS), cnt = SPI(ADC_COUNT);
    kv("adc ctrl", ctrl); kv("adc status", st); kv("adc count", cnt);
    check(0, !(ctrl & A_RUN) && !(st & A_RUNNING) && cnt == 0u, "reader not idle after the reset");
    check(1, adc_block(), "no full block");
    st = SPI(ADC_STATUS);
    kv("adc status", st); kv("adc count", SPI(ADC_COUNT));
    check(2, !(st & (A_OVERRUN | A_BUSERR)), "overrun or bus error");
    volatile uint16_t *s = (volatile uint16_t *)BUF0;
    uint32_t same = 1;
    for (int i = 1; i < 128; i++) {
        if (s[i] != s[0]) same = 0;
#ifdef RAMP
        if (((uint16_t)(s[i] - s[i - 1]) & 0x3FFFu) != 1237u) fail |= 1u << 4;
#endif
    }
    check(3, !same, "samples all equal");
#ifdef RAMP
    check(4, !(fail & (1u << 4)), "ramp");
#endif
    return finish("STEP9");
}
