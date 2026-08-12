// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
//
// Same program as sim/sw/blink/blink.c, but linked by this directory's
// link.ld to execute in place from QSPI flash (origin 0x2000_0000) instead
// of SRAM -- see the "QSPI boot" note at the bottom of this file for the
// two-file workflow this needs (trampoline via JTAG + this program flashed
// onto the physical QSPI chip). Blinks GPIO pin 0 (LD0) forever.

#include "gpio.h"
#include "util.h"
#include "config.h"

#define LED_PIN 0

static inline uint32_t get_mcycle32(void) {
    uint32_t val;
    asm volatile("csrr %0, mcycle" : "=r"(val));
    return val;
}

static void delay_ms(uint32_t ms) {
    uint32_t cycles = (TB_FREQUENCY / 1000) * ms;
    uint32_t start  = get_mcycle32();
    while ((get_mcycle32() - start) < cycles) { }
}

int main() {
    gpio_pin_set_output(LED_PIN);
    gpio_pin_enable(LED_PIN);

    while (1) {
        gpio_pin_toggle(LED_PIN);
        delay_ms(500);
    }
}

// ---------------------------------------------------------------------
// QSPI boot workflow (see this directory's link.ld: .vectors/.text._start/
// .text/.rodata are placed at flash origin 0x2000_0000; only .bss/.data,
// of which this program has none, would live in SRAM at 0x1000_0000):
//
//   1. Flash bin/blink_flash.bin onto the physical QSPI chip at its own
//      offset 0 (e.g. via the TinyTapeout Pmod Flasher + Pico 2 W).
//   2. Via JTAG/GDB, `load` qspi_boot_trampoline.hex -- NOT blink.hex.
//      It's a 16-byte stub placed at the SRAM base (0x1000_0000, which is
//      also soc_ctrl's BOOTADDR reset default) that does `lui t0,0x20000;
//      jr t0`, redirecting the normal boot path into flash.
//   3. Wake the core from bootrom's wfi as usual (CLINT msip -- automatic
//      if using the openocd-croc.cfg in this directory), then `continue`.
// ---------------------------------------------------------------------
