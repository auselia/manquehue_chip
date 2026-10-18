// Register test of the SPI block from the CPU (fits the 2 KB SRAM). It checks the address map of the user domain
// (SPI block at 0x2200_0000) and byte, halfword and word access to the ADC reader registers.
// Prints "SPI REGS OK" on the UART and returns 0, or prints "SPI REGS FAIL" and returns a bit mask of the failed checks.
#include <stdint.h>
#include "uart.h"

#define SPI_BASE   0x22000000u
#define REG32(off) (*(volatile uint32_t *)(SPI_BASE + (off)))
#define REG16(off) (*(volatile uint16_t *)(SPI_BASE + (off)))
#define REG8(off)  (*(volatile uint8_t  *)(SPI_BASE + (off)))

#define ADC_CTRL  0x100
#define ADC_BUF0  0x108
#define ADC_NSAMP 0x110
#define ADC_PINS  0x120

static void puts_uart(const char *s) {
    for (int i = 0; s[i]; i++) uart_write(s[i]);
}

int main() {
    uint32_t fail = 0;
    uart_init();

    if (REG32(ADC_CTRL)  != 0x4300u) fail |= 1u << 0;   // TRIG_ACTIVE_LOW, IDLE 3
    if (REG32(ADC_NSAMP) != 128u)    fail |= 1u << 1;
    if (REG32(ADC_PINS)  != 0x302u)  fail |= 1u << 2;   // CAP_EN 1, WAKE_N and BIG_N inputs high
    if (REG32(0x000)     != 0u)      fail |= 1u << 3;   // radio block: not yet in, reads 0

    REG32(ADC_BUF0) = 0x10000403u;                       // low two bits are forced to 0
    if (REG32(ADC_BUF0) != 0x10000400u) fail |= 1u << 4;
    REG16(ADC_BUF0 + 2) = 0x1234u;                       // upper halfword
    REG8(ADC_BUF0) = 0x80u;                              // byte 0
    if (REG32(ADC_BUF0) != 0x12340480u) fail |= 1u << 5;

    REG32(ADC_NSAMP) = 2000u;                            // clamped to 1024
    if (REG32(ADC_NSAMP) != 1024u) fail |= 1u << 6;
    REG8(ADC_NSAMP) = 0x07u;                             // 0x407 -> above 1024 -> 1024
    if (REG32(ADC_NSAMP) != 1024u) fail |= 1u << 7;
    REG16(ADC_NSAMP) = 0x0021u;                          // odd -> 32
    if (REG32(ADC_NSAMP) != 32u) fail |= 1u << 8;

    puts_uart(fail ? "SPI REGS FAIL\n" : "SPI REGS OK\n");
    uart_write_flush();
    return (int)fail;
}
