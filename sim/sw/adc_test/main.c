// Copyright and related rights waived via CC0.
//
// obi_spi_host bring-up test #2: MCP3008 (cheap 10-bit, 8-channel SPI ADC)
// on CS1. This is NOT the real cavitation ADC -- it's a $3, through-hole,
// dead-simple SPI part used only to prove the pinmux + obi_spi_host +
// dual-chip-select path actually works, independent of anything
// piezo/cavitation-specific. Wire a potentiometer (or a simple resistor
// divider) between 3.3V and GND into MCP3008 CH0; the reading below should
// track wherever you set the pot.
//
// Wiring (see rtl/fpga/croc_zedboard_top.sv + constraints/zedboard.xdc):
//   MCP3008 CS/SHDN -> Pmod JD pin2 (gpio0_io pad, csb_o[1] once pinmux is set)
//   MCP3008 CLK     -> Pmod JB pin1 (uart_tx_o pad)
//   MCP3008 DIN     -> Pmod JD pin3 (gpio1_io pad, sd_o[0])
//   MCP3008 DOUT    -> Pmod JB pin2 (uart_rx_i pad)
//   MCP3008 VDD/VREF -> 3.3V, AGND/DGND -> GND (do not use 5V)
//
// Same UART/pinmux caveat as lora_test: results are printed *between*
// transfers, not during them, and a JTAG probe must stay attached for the
// whole session (this SoC's bootrom always waits on CLINT.msip from a
// debugger -- see rtl/bootrom/README.md).

#include <stdint.h>
#include "config.h"
#include "util.h"
#include "uart.h"
#include "print.h"
#include "pinmux.h"
#include "spi_host.h"

#define ADC_CSID 1

// Same conservative 400 kHz as lora_test -- MCP3008 tops out around
// 1.2-1.35 MHz depending on supply, so this has plenty of margin.
#define ADC_CONFIGOPTS \
    (SPI_HOST_CFG_CLKDIV(24) | SPI_HOST_CFG_CSNLEAD(2) | \
     SPI_HOST_CFG_CSNTRAIL(2) | SPI_HOST_CFG_CSNIDLE(2))
    // CPOL=0, CPHA=0 (mode 0,0) -- one of the two modes MCP3008 supports

// printf here only implements %x (see lib/src/print.c) -- this is a
// minimal decimal formatter so the ADC code/voltage are readable without
// touching that shared, deliberately tiny library.
static void print_dec(uint32_t v) {
    char buf[10];
    int i = 0;
    if (v == 0) {
        putchar('0');
        return;
    }
    while (v > 0 && i < 10) {
        buf[i++] = '0' + (v % 10);
        v /= 10;
    }
    while (i > 0) {
        putchar(buf[--i]);
    }
}

// Standard MCP3008 single-ended-conversion framing:
//   TX: {0x01, 0x80 | (channel << 4), 0x00}
//   RX: 10-bit result spans the low 2 bits of rx[1] and all of rx[2]
static uint16_t mcp3008_read(uint8_t channel) {
    uint8_t tx[3] = {0x01, (uint8_t)(0x80u | ((channel & 0x7u) << 4)), 0x00};
    uint8_t rx[3] = {0, 0, 0};
    spi_host_transfer(ADC_CSID, tx, rx, 3, 0);
    return (uint16_t)(((rx[1] & 0x03u) << 8) | rx[2]);
}

int main(void) {
    uart_init();
    printf("=== obi_spi_host bring-up: MCP3008 CH0 (CS1) ===\n");
    printf("(this is a bring-up ADC, not the real cavitation sensor)\n");
    uart_write_flush();

    spi_host_init();
    spi_host_configure(ADC_CSID, ADC_CONFIGOPTS);

    for (int sample = 0; sample < 20; sample++) {
        pinmux_set(PINMUX_ALL);
        uint16_t code = mcp3008_read(0);
        pinmux_set(0);

        uint32_t mv = ((uint32_t)code * 3300u) / 1023u; // assuming 3.3V VREF

        printf("CH0 = ");
        print_dec(code);
        printf(" / 1023  (~");
        print_dec(mv);
        printf(" mV)\n");
        uart_write_flush();

        for (volatile int d = 0; d < 2000000; d++) {
        } // crude inter-sample delay, nothing timing-critical here
    }

    printf("Done. Turn the pot and re-run -- the reading should track it.\n");
    uart_write_flush();

    while (1) {
        wfi();
    }
    return 0;
}
