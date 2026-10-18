// Radio master test from the QSPI flash. The SoC testbench (rtl/test/tb_croc_soc.sv) puts the SX1276 model
// (sim/models/sx1276_model.v) on the rf_* pins. The program releases the radio reset, reads RegVersion, writes and
// reads back a burst of registers, writes a 16-byte payload into the radio FIFO and reads it back (17-byte transfers,
// more than the 8-byte FIFOs of rf_spi), starts TX and waits for DIO0, then clears the radio flag.
// Prints "SPI RADIO OK" and returns 0, or prints "SPI RADIO FAIL" and returns a bit mask of the failed checks.
#include <stdint.h>
#include "uart.h"

#define SPI_BASE   0x22000000u
#define REG32(off) (*(volatile uint32_t *)(SPI_BASE + (off)))

#define RF_CTRL    0x00
#define RF_STATUS  0x04
#define RF_CMD     0x08
#define RF_DATA    0x0C
#define RF_IRQ_EN  0x10
#define RF_IRQ_ST  0x14
#define RF_PINS    0x18
#define RF_ERR     0x1C

#define CTRL_EN          (1u << 0)
#define CTRL_CLKDIV(n)   ((uint32_t)(n) << 8)
#define CTRL_CS_SETUP(n) ((uint32_t)(n) << 16)
#define ST_TX_FULL       (1u << 2)
#define ST_RX_EMPTY      (1u << 3)
#define IRQ_DONE         (1u << 0)
#define IRQ_DIO0         (1u << 4)
#define PINS_RSTN        (1u << 0)
#define PINS_DIO0        (1u << 8)

#define NPAY 16

static void puts_uart(const char *s) {
    for (int i = 0; s[i]; i++) uart_write(s[i]);
}

// One transfer of n bytes with CS low. Pushes the TX bytes and pops the RX bytes as the FIFOs allow, so n can be
// larger than the FIFOs. tx = 0 sends zeros, rx = 0 drops the received bytes. Returns 0 on a timeout.
static int rf_xfer(const uint8_t *tx, uint8_t *rx, uint32_t n) {
    uint32_t i = 0, j = 0, t = 0;
    REG32(RF_CMD) = n;
    while (j < n) {
        if (++t > 100000u) return 0;
        uint32_t st = REG32(RF_STATUS);
        if (i < n && !(st & ST_TX_FULL)) {
            REG32(RF_DATA) = tx ? tx[i] : 0u;
            i++;
        } else if (!(st & ST_RX_EMPTY)) {
            uint8_t b = (uint8_t)REG32(RF_DATA);
            if (rx) rx[j] = b;
            j++;
        }
    }
    for (t = 0; !(REG32(RF_IRQ_ST) & IRQ_DONE); t++)
        if (t > 10000u) return 0;
    REG32(RF_IRQ_ST) = IRQ_DONE;
    return 1;
}

static uint8_t tx[NPAY + 1], rx[NPAY + 1], payload[NPAY];

int main() {
    uint32_t fail = 0;
    uint32_t ok = 1;                                         // all transfers finished
    uart_init();

    if (REG32(RF_PINS) != 0u) fail |= 1u << 0;              // reset: radio held in reset, DIO0 low
    REG32(RF_PINS) = PINS_RSTN;
    REG32(RF_CTRL) = CTRL_EN | CTRL_CLKDIV(2) | CTRL_CS_SETUP(1);

    // RegVersion (0x42) = 0x12
    tx[0] = 0x42; tx[1] = 0;
    ok &= rf_xfer(tx, rx, 2);
    if (rx[1] != 0x12) fail |= 1u << 1;

    // burst write RegFrfMsb..Lsb (0x06..0x08) = 0x6C 0x80 0x00 (868 MHz), burst read back
    tx[0] = 0x80 | 0x06; tx[1] = 0x6C; tx[2] = 0x80; tx[3] = 0x00;
    ok &= rf_xfer(tx, 0, 4);
    tx[0] = 0x06; tx[1] = tx[2] = tx[3] = 0;
    ok &= rf_xfer(tx, rx, 4);
    if (rx[1] != 0x6C || rx[2] != 0x80 || rx[3] != 0x00) fail |= 1u << 2;

    // payload into the radio FIFO at FifoTxBaseAddr 0x80, PayloadLength 16, then read it back
    for (int k = 0; k < NPAY; k++) payload[k] = (uint8_t)(k * 37 + 5);
    tx[0] = 0x80 | 0x0D; tx[1] = 0x80;                       // FifoAddrPtr = 0x80
    ok &= rf_xfer(tx, 0, 2);
    tx[0] = 0x80 | 0x00;
    for (int k = 0; k < NPAY; k++) tx[k + 1] = payload[k];
    ok &= rf_xfer(tx, 0, NPAY + 1);
    tx[0] = 0x80 | 0x22; tx[1] = NPAY;                       // PayloadLength
    ok &= rf_xfer(tx, 0, 2);
    tx[0] = 0x80 | 0x0D; tx[1] = 0x80;
    ok &= rf_xfer(tx, 0, 2);
    tx[0] = 0x00;
    for (int k = 0; k < NPAY; k++) tx[k + 1] = 0;
    ok &= rf_xfer(tx, rx, NPAY + 1);
    for (int k = 0; k < NPAY; k++) if (rx[k + 1] != payload[k]) fail |= 1u << 3;

    // TX: RegOpMode = LoRa | TX. The radio raises DIO0 (TxDone) when the payload is sent.
    REG32(RF_IRQ_EN) = IRQ_DIO0;
    tx[0] = 0x80 | 0x01; tx[1] = 0x83;
    ok &= rf_xfer(tx, 0, 2);
    uint32_t t;
    for (t = 0; t < 20000u && !(REG32(RF_IRQ_ST) & IRQ_DIO0); t++) { }
    if (!(REG32(RF_IRQ_ST) & IRQ_DIO0)) fail |= 1u << 4;
    if (!(REG32(RF_PINS) & PINS_DIO0)) fail |= 1u << 4;

    // RegIrqFlags (0x12) has TxDone (bit 3). Write 1 to clear it, DIO0 falls. RegOpMode is back to standby.
    tx[0] = 0x12; tx[1] = 0;
    ok &= rf_xfer(tx, rx, 2);
    if (!(rx[1] & 0x08)) fail |= 1u << 5;
    tx[0] = 0x80 | 0x12; tx[1] = 0x08;
    ok &= rf_xfer(tx, 0, 2);
    for (t = 0; t < 1000u && (REG32(RF_PINS) & PINS_DIO0); t++) { }
    if (REG32(RF_PINS) & PINS_DIO0) fail |= 1u << 5;
    REG32(RF_IRQ_ST) = IRQ_DIO0;
    if (REG32(RF_IRQ_ST) & IRQ_DIO0) fail |= 1u << 5;
    tx[0] = 0x01; tx[1] = 0;
    ok &= rf_xfer(tx, rx, 2);
    if (rx[1] != 0x81) fail |= 1u << 6;

    if (REG32(RF_ERR) != 0u) fail |= 1u << 7;
    if (!ok) fail |= 1u << 8;
    REG32(RF_CTRL) = CTRL_CLKDIV(2) | CTRL_CS_SETUP(1);       // EN = 0

    puts_uart(fail ? "SPI RADIO FAIL\n" : "SPI RADIO OK\n");
    uart_write_flush();
    return (int)fail;
}
