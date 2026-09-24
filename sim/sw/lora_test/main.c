// Copyright and related rights waived via CC0.
//
// obi_spi_host bring-up test #1: SX1276/77/78/79 (RFM9x LoRa module) on CS0.
//
// Wiring (see rtl/fpga/croc_zedboard_top.sv + constraints/zedboard.xdc):
//   LoRa NSS  -> Pmod JD pin1 (status_o pad, csb_o[0] once pinmux is set)
//   LoRa SCK  -> Pmod JB pin1 (uart_tx_o pad)
//   LoRa MOSI -> Pmod JD pin3 (gpio1_io pad, sd_o[0])
//   LoRa MISO -> Pmod JB pin2 (uart_rx_i pad)
//   LoRa VCC/GND -> Pmod JD/JB's 3V3/GND pins (3.3V only -- do not use 5V)
//
// Does nothing RF-related on purpose: RegVersion is a read-only register
// that always returns 0x12 on SX1276/77/78/79, with no antenna, no
// frequency setup, and no risk of transmitting anything. It's purely a
// "is the digital SPI link wired and working" check -- exactly what this
// bring-up needs before anything LoRa-specific gets built on top.
//
// UART is stolen the instant the pinmux goes into SPI mode (SCK/MISO share
// its pins), so results are only printed *between* transfers, not during
// them -- see pinmux.h. A JTAG probe is required regardless: this SoC's
// bootrom always parks in `wfi` waiting for the debugger to set CLINT.msip
// (see rtl/bootrom/README.md), there's no autonomous boot path yet.

#include <stdint.h>
#include "config.h"
#include "util.h"
#include "uart.h"
#include "print.h"
#include "pinmux.h"
#include "spi_host.h"

#define LORA_CSID 0

// CLKDIV=24 -> sck = TB_FREQUENCY / (2*(24+1)) = 400 kHz. Conservative for a
// first bring-up (SX1276 supports up to 10 MHz); raise once this passes.
#define LORA_CONFIGOPTS \
    (SPI_HOST_CFG_CLKDIV(24) | SPI_HOST_CFG_CSNLEAD(2) | \
     SPI_HOST_CFG_CSNTRAIL(2) | SPI_HOST_CFG_CSNIDLE(2))
    // CPOL=0, CPHA=0 (mode 0,0) -- SX1276 requires this exact mode

#define SX127X_REG_VERSION 0x42

int main(void) {
    uart_init();
    printf("=== obi_spi_host bring-up: SX1276 RegVersion read (CS0) ===\n");
    uart_write_flush();

    spi_host_init();
    spi_host_configure(LORA_CSID, LORA_CONFIGOPTS);

    // Read register: MSB=0 selects a read. Byte 0 = address, byte 1 = dummy
    // clocked out while the device shifts the register value back on MISO.
    uint8_t tx[2] = {SX127X_REG_VERSION & 0x7F, 0x00};
    uint8_t rx[2] = {0, 0};

    pinmux_set(PINMUX_ALL);              // steal uart/gpio0/gpio1/status_o for SPI
    spi_host_transfer(LORA_CSID, tx, rx, 2, 0);
    pinmux_set(0);                        // give them back to uart/gpio/status_o

    printf("RegVersion = 0x%x  (expect 0x12 for SX1276/77/78/79)\n", rx[1]);
    if (rx[1] == 0x12) {
        printf("PASS -- LoRa module responds correctly over SPI.\n");
    } else if (rx[1] == 0x00 || rx[1] == 0xFF) {
        printf("FAIL -- looks like no response at all (0x%x). Check NSS/SCK/MOSI/MISO\n", rx[1]);
        printf("wiring and that the module has 3.3V power.\n");
    } else {
        printf("FAIL -- unexpected value. Check CS0 assignment and wiring.\n");
    }
    uart_write_flush();

    while (1) {
        wfi();
    }
    return 0;
}
