// Copyright and related rights waived via CC0.
//
// obi_spi_host + ADS7057 (14-bit, 2.5-MSPS, differential SAR ADC): the
// real cavitation-sensor ADC, on CS1 -- same chip-select the MCP3008
// bring-up test (adc_test/) used to prove the pinmux + obi_spi_host path
// generically. LORA_CSID (lora_test/) is 0, so this project's actual
// wiring is: SX1276 -> CS0 (status_o pad), ADS7057 -> CS1 (gpio0 pad).
//
// Wiring (see rtl/fpga/croc_zedboard_top.sv + constraints/zedboard.xdc,
// and croc_soc.sv's pinmux pad-sharing note):
//   ADS7057 CS   -> gpio0_io pad (csb_o[1] once pinmux is set)
//   ADS7057 SCLK -> uart_tx_o pad
//   ADS7057 SDO  -> uart_rx_i pad
//   ADS7057 has no MOSI/DIN pin -- gpio1_io (the shared MOSI pad) is simply
//   unused by this device.
//
// Same UART/pinmux caveat as adc_test/lora_test: results are printed
// *between* transfers, not during them (pinmux_set(PINMUX_ALL) steals the
// console pad for the duration of each spi_host_transfer), and a JTAG
// probe must stay attached for the whole session (bootrom always waits on
// CLINT.msip from a debugger -- see rtl/bootrom/README.md).

#include <stdint.h>
#include "config.h"
#include "util.h"
#include "uart.h"
#include "print.h"
#include "pinmux.h"
#include "spi_host.h"
#include "ads7057.h"

#define ADS7057_CSID 1

// Conservative starting point for bring-up -- SCLK = sys_clk/2 = 10 MHz at
// this testbench's 20 MHz clock, well under the ADS7057's 60 MHz max.
// Recompute for the real Zedboard system clock before board bring-up.
#define ADS7057_CLKDIV 0

static void print_dec_signed(int32_t v) {
    if (v < 0) {
        putchar('-');
        v = -v;
    }
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

int main(void) {
    uart_init();
    printf("=== ADS7057 cavitation ADC bring-up (CS1) ===\n");
    uart_write_flush();

    spi_host_init();
    spi_host_configure(ADS7057_CSID, ADS7057_CONFIGOPTS(ADS7057_CLKDIV));

    // Throwaway read: ADS7057 pipelines its output by one frame, so the
    // very first read returns whatever the ADC happened to be converting
    // before this loop ever asserted CS -- not a defined value. Discard it.
    pinmux_set(PINMUX_ALL);
    (void)ads7057_read(ADS7057_CSID);
    pinmux_set(0);

    for (int sample = 0; sample < 20; sample++) {
        pinmux_set(PINMUX_ALL);
        int32_t code = ads7057_read(ADS7057_CSID);
        pinmux_set(0);

        printf("code = ");
        print_dec_signed(code);
        printf(" (14-bit signed)\n");
        uart_write_flush();

        for (volatile int d = 0; d < 2000000; d++) {
        } // crude inter-sample delay, nothing timing-critical here
    }

    printf("Done.\n");
    uart_write_flush();

    while (1) {
        wfi();
    }
    return 0;
}
