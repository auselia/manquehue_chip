// First program from the QSPI flash: checks that .data was copied and .bss cleared by crt0_flash.S,
// that a const table is read from the flash, prints "FLASH OK" and returns 0 (or a bit mask of the failures).
#include <stdint.h>
#include "uart.h"

static uint32_t initialised = 0x5A5A1234u;           // .data: initial value copied from the flash
static uint32_t zeroed[4];                           // .bss: cleared
static const char msg_ok[]   = "FLASH OK\n";         // .rodata: read from the flash
static const char msg_fail[] = "FLASH FAIL\n";

static void puts_uart(const char *s) {
    for (int i = 0; s[i]; i++) uart_write(s[i]);
}

int main() {
    uint32_t fail = 0;
    uart_init();
    if (initialised != 0x5A5A1234u) fail |= 1u << 0;
    for (int i = 0; i < 4; i++) if (zeroed[i] != 0) fail |= 1u << 1;
    if ((uint32_t)&main < 0x20000000u) fail |= 1u << 2;            // the code really is in the flash
    if ((uint32_t)&initialised >= 0x10000800u || (uint32_t)&initialised < 0x10000000u) fail |= 1u << 3;
    initialised++;                                                  // data is writable
    if (initialised != 0x5A5A1235u) fail |= 1u << 4;
    puts_uart(fail ? msg_fail : msg_ok);
    uart_write_flush();
    return (int)fail;
}
