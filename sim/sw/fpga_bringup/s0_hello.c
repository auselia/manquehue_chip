// Step 0, bring-up: UART, GPIO on LD0/LD1, mcycle and the 32.768 kHz mtime. The GPIO input register reads 0 for a pin
// set as an output (rtl/gpio/gpio.sv: sync_in = in & is_input), so the LEDs are the GPIO check: watch them.
// Expect "STEP0 OK" and LD0/LD1 blinking in turn 5 times. LD3 is on (reset released), LD7 blinks (heartbeat).
#include "bringup.h"
int main() {
    fail = 0;                                              // .bss is not cleared by the SRAM crt0: no stale value
    uart_init();
    put("STEP0 bring-up\n");
    GPIO(0x000) = 3u;                                      // LD0, LD1 outputs
    GPIO(0x080) = 3u;                                      // enabled
    uint32_t m0 = MTIME, c0 = mcycle();
    for (int i = 0; i < 10; i++) {
        uint32_t v = (i & 1) ? 2u : 1u;
        GPIO(0x180) = v;
        wait_cycles(CLK_HZ / 20);                          // 50 ms
    }
    GPIO(0x180) = 0u;
    uint32_t dm = MTIME - m0, dc = mcycle() - c0;
    kv("mcycle", dc); kv("mtime", dm);
    check(1, dc >= CLK_HZ / 2, "mcycle");
    // one mtime tick every 610 cycles (20 MHz / 610 = 32.787 kHz). Accept 12.5 %. No multiplier or divider in
    // croc (rv32i): 610 = 512 + 64 + 32 + 2.
    uint32_t p = (dm << 9) + (dm << 6) + (dm << 5) + (dm << 1), e = p > dc ? p - dc : dc - p;
    check(2, e < (dc >> 3), "mtime rate");
    return finish("STEP0");
}
