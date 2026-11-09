// Test of the QSPI command engine (rtl/obi_qspi/qspi_cmd.sv) with the W25Q flash on CS0 and the two APS6404L PSRAMs
// on CS1 and CS2 (the TinyTapeout QSPI Pmod). Runs from the SRAM: code that sends commands to the flash must not
// run from the flash.
//  1. flash JEDEC ID = EF 40 18
//  2. sector erase at TADDR, then the flash window reads 0xFFFFFFFF there
//  3. page program of 16 bytes at TADDR with qspi_cmd, read back through the flash window
//  4. stores into the flash window (qqspi page program) after a write enable: word, byte and halfword, read back
//  5. QE bit: write status 2 = 0x02, read status 2
//  6. PSRAM ID on CS1 and CS2 = 0D 5D, then words written and read in single mode, then in quad mode (QCTRL)
// UART: one line per failing step, then "QSPI CMD OK" or "QSPI CMD FAIL <mask>" (bit n = step n).
#include <stdint.h>
#include "uart.h"

#define QC_BASE  0x22002000u
#define QC(o)    (*(volatile uint32_t *)(QC_BASE + (o)))
#define Q_CTRL   0x00
#define Q_STATUS 0x04
#define Q_CMD    0x08
#define Q_DATA   0x0C
#define Q_IRQST  0x14
#define Q_QCTRL  0x20
#define ST_TX_FULL  (1u << 2)
#define ST_RX_EMPTY (1u << 3)

#define FLASH  0x20000000u
#define PSRAM0 0x21000000u
#define PSRAM1 0x21800000u
#define W(a)   (*(volatile uint32_t *)(a))
#define H(a)   (*(volatile uint16_t *)(a))
#define B(a)   (*(volatile uint8_t *)(a))

#define TADDR  0x010000u                                   // flash test sector (4 KB)
#define TIMEOUT 2000000u

static uint32_t fail;
static uint32_t mcycle(void) { uint32_t v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }
static void put(const char *s) { while (*s) uart_write(*s++); }
static void put_hex(uint32_t v) { for (int i = 28; i >= 0; i -= 4) uart_write("0123456789abcdef"[(v >> i) & 15]); }
static void bad(int step, uint32_t v) { fail |= 1u << step; put("step "); put_hex(step); put(" got "); put_hex(v); put("\n"); }

// one command on device cs: ntx bytes out of tx, then nrx bytes into rx (CS low for all of them)
static void cmd(uint32_t cs, const uint8_t *tx, uint32_t ntx, uint8_t *rx, uint32_t nrx) {
    uint32_t n = ntx + nrx, i = 0, j = 0, t0 = mcycle();
    // Flash (CS0) in SPI mode 3: the pins go back to obi_qspi in the cycle that CS rises, and its idle SCLK is 1. In
    // mode 0 that is a rising SCLK edge together with the CS rise, the W25Q counts a 9th clock and drops every
    // command it runs at CS rise (06, 04, 20, 02, 31, 66/99). Seen on the ZedBoard, 9 Nov 2026. The PSRAMs pass in
    // mode 0.
    QC(Q_CTRL) = (QC(Q_CTRL) & ~0xCu) | (cs == 0 ? 0xCu : 0u);
    QC(Q_QCTRL) = (QC(Q_QCTRL) & ~3u) | cs;
    QC(Q_CMD) = n;
    while (j < n) {
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 7; return; }
        uint32_t st = QC(Q_STATUS);
        if (i < n && !(st & ST_TX_FULL)) {
            QC(Q_DATA) = (i < ntx) ? tx[i] : 0xFF;
            i++;
        } else if (!(st & ST_RX_EMPTY)) {
            uint8_t b = (uint8_t)QC(Q_DATA);
            if (j >= ntx && rx) rx[j - ntx] = b;
            j++;
        }
    }
    while (!(QC(Q_IRQST) & 1u)) if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 7; return; }
    QC(Q_IRQST) = 1u;
}
static void op(uint8_t c) { cmd(0, &c, 1, 0, 0); }
static void wait_ready(void) {                             // read status 1 until BUSY = 0
    uint8_t c = 0x05, s;
    uint32_t t0 = mcycle();
    do { cmd(0, &c, 1, &s, 1); } while ((s & 1u) && mcycle() - t0 < TIMEOUT);
    if (s & 1u) fail |= 1u << 7;
}

int main() {
    fail = 0;                                              // .bss is not cleared by the SRAM crt0: no stale value
    uart_init();
    uint8_t b[24], r[4];
    QC(Q_CTRL) = 1u | (1u << 8) | (1u << 16);              // EN, mode 0, CLKDIV 1 (SCLK = clk / 4), CS_SETUP 1

    // 1. JEDEC ID
    b[0] = 0x9F; cmd(0, b, 1, r, 3);
    uint32_t id = (r[0] << 16) | (r[1] << 8) | r[2];
    if (id != 0xEF4018u && id != 0xEF7018u) bad(1, id);           // W25Q128JV-IQ or -IM/JM

    // 2. sector erase
    op(0x06);
    b[0] = 0x20; b[1] = (uint8_t)(TADDR >> 16); b[2] = (uint8_t)(TADDR >> 8); b[3] = (uint8_t)TADDR;
    cmd(0, b, 4, 0, 0);
    wait_ready();
    if (W(FLASH + TADDR) != 0xFFFFFFFFu) bad(2, W(FLASH + TADDR));

    // 3. page program of 16 bytes
    op(0x06);
    b[0] = 0x02;                                           // b[1..3] = TADDR
    for (int i = 0; i < 16; i++) b[4 + i] = (uint8_t)(0x10 + 7 * i);
    cmd(0, b, 20, 0, 0);
    wait_ready();
    for (int i = 0; i < 4; i++) {
        uint32_t e = (uint32_t)b[4 + 4 * i] | (b[5 + 4 * i] << 8) | (b[6 + 4 * i] << 16) | ((uint32_t)b[7 + 4 * i] << 24);
        if (W(FLASH + TADDR + 4 * i) != e) bad(3, W(FLASH + TADDR + 4 * i));
    }

    // 4. store into the flash window after a write enable
    op(0x06);
    W(FLASH + TADDR + 0x100) = 0x5A5AC3C3u;
    wait_ready();
    if (W(FLASH + TADDR + 0x100) != 0x5A5AC3C3u) bad(4, W(FLASH + TADDR + 0x100));
    op(0x06);
    B(FLASH + TADDR + 0x105) = 0x77;                       // byte lane 1
    wait_ready();
    if (W(FLASH + TADDR + 0x104) != 0xFFFF77FFu) bad(4, W(FLASH + TADDR + 0x104));
    op(0x06);
    H(FLASH + TADDR + 0x10A) = 0x1234;                     // upper halfword
    wait_ready();
    if (W(FLASH + TADDR + 0x108) != 0x1234FFFFu) bad(4, W(FLASH + TADDR + 0x108));

    // 5. QE bit
    op(0x06);
    b[0] = 0x31; b[1] = 0x02; cmd(0, b, 2, 0, 0);
    wait_ready();
    b[0] = 0x35; cmd(0, b, 1, r, 1);
    if (!(r[0] & 2u)) bad(5, r[0]);

    // 6. PSRAM: ID, single, quad
    for (uint32_t cs = 1; cs <= 2; cs++) {
        b[0] = 0x9F; b[1] = b[2] = b[3] = 0; cmd(cs, b, 4, r, 2);
        if (r[0] != 0x0D || r[1] != 0x5D) bad(6, (cs << 16) | (r[0] << 8) | r[1]);
    }
    W(PSRAM0 + 0x40) = 0x01234567u;
    W(PSRAM1 + 0x40) = 0x89ABCDEFu;
    if (W(PSRAM0 + 0x40) != 0x01234567u) bad(6, W(PSRAM0 + 0x40));
    if (W(PSRAM1 + 0x40) != 0x89ABCDEFu) bad(6, W(PSRAM1 + 0x40));
    QC(Q_QCTRL) = QC(Q_QCTRL) | (3u << 4);                 // both PSRAMs in quad
    if (W(PSRAM0 + 0x40) != 0x01234567u) bad(6, W(PSRAM0 + 0x40));   // written in single, read in quad
    W(PSRAM0 + 0x80) = 0xCAFEF00Du;
    W(PSRAM1 + 0x80) = 0x0BADBEEFu;
    if (W(PSRAM0 + 0x80) != 0xCAFEF00Du) bad(6, W(PSRAM0 + 0x80));
    if (W(PSRAM1 + 0x80) != 0x0BADBEEFu) bad(6, W(PSRAM1 + 0x80));
    B(PSRAM0 + 0x81) = 0x11;                               // byte and halfword stores in quad
    H(PSRAM1 + 0x82) = 0x2233;
    if (W(PSRAM0 + 0x80) != 0xCAFE110Du) bad(6, W(PSRAM0 + 0x80));
    if (W(PSRAM1 + 0x80) != 0x2233BEEFu) bad(6, W(PSRAM1 + 0x80));

    if (fail) { put("QSPI CMD FAIL "); put_hex(fail); put("\n"); }
    else put("QSPI CMD OK\n");
    uart_write_flush();
    return (int)fail;
}
