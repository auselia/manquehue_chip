// Step 2b, flasher: writes a program image from PSRAM A into the QSPI flash, so that croc boots it from the flash.
// Runs from the SRAM (loaded over JTAG). OpenOCD first writes the image file <step>.psram.bin (flash_step.sh) to
// PSRAM A at 0x2100_0000: word 0 = image length in bytes, then the flash image (word 0 of the image = "CROC").
//  1. check the length and the magic
//  2. erase the 4 KB sectors from flash address 0
//  3. page program, 256 B per page: PSRAM -> SRAM page buffer -> flash (the command engine and the memory window
//     share the pins, so a page is copied to the SRAM first)
//  4. read back through the flash window and compare with the PSRAM
// UART: "FLASH WRITE OK <length>" or "FLASH WRITE FAIL <mask>". Then press BTNC: the bootrom finds "CROC" and runs
// the program from the flash. -DBOOT (simulation) jumps to it directly, with ra at the bootrom _eoc.
#include "bringup.h"

#define QC_BASE  0x22002000u
#define QC(o)    (*(volatile uint32_t *)(QC_BASE + (o)))
#define Q_CTRL   0x00
#define Q_STATUS 0x04
#define Q_CMD    0x08
#define Q_DATA   0x0C
#define Q_IRQST  0x14
#define Q_QCTRL  0x20
#define FLASH  0x20000000u
#define PSRAM0 0x21000000u
#define W(a)   (*(volatile uint32_t *)(a))

static uint8_t page[4 + 256];

// one command to the flash (CS0): n bytes out of tx, the last nrx of them read back into rx
static void cmd(const uint8_t *tx, uint32_t n, uint8_t *rx, uint32_t nrx) {
    uint32_t i = 0, j = 0, t0 = mcycle();
    QC(Q_QCTRL) = QC(Q_QCTRL) & ~3u;
    QC(Q_CMD) = n;
    while (j < n) {
        if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 7; return; }
        uint32_t st = QC(Q_STATUS);
        if (i < n && !(st & ST_TX_FULL)) { QC(Q_DATA) = tx[i]; i++; }
        else if (!(st & ST_RX_EMPTY)) { uint8_t b = (uint8_t)QC(Q_DATA); if (rx && j >= n - nrx) rx[j - (n - nrx)] = b; j++; }
    }
    while (!(QC(Q_IRQST) & 1u)) if (mcycle() - t0 > TIMEOUT) { fail |= 1u << 7; return; }
    QC(Q_IRQST) = 1u;
}
static void wren(void) { uint8_t c = 0x06; cmd(&c, 1, 0, 0); }
static void wait_ready(void) {
    uint8_t c[2] = {0x05, 0}, s = 1;
    uint32_t t0 = mcycle();
    while ((s & 1u) && mcycle() - t0 < 4u * TIMEOUT) cmd(c, 2, &s, 1);
    if (s & 1u) fail |= 1u << 7;
}
static void addr_cmd(uint8_t op, uint32_t a) { page[0] = op; page[1] = a >> 16; page[2] = a >> 8; page[3] = a; }

int main() {
    fail = 0;                                              // .bss is not cleared by the SRAM crt0: no stale value
    uart_init();
    put("STEP2b flasher\n");
    // EN, SPI mode 3, SCLK = clk / 4, CS_SETUP 1. Mode 3: in mode 0 the pin handover to obi_qspi (idle SCLK 1) adds a
    // rising SCLK edge at the CS rise, and the W25Q drops write enable, erase and program (ZedBoard, 9 Nov 2026).
    QC(Q_CTRL) = 1u | (1u << 2) | (1u << 3) | (1u << 8) | (1u << 16);
    uint32_t len = W(PSRAM0);
    kv("length", len);
    if (len < 8u || len > 0x100000u || W(PSRAM0 + 4) != 0x434F5243u) {
        fail |= 1u << 1;
        return finish("FLASH WRITE");
    }
    len = (len + 3u) & ~3u;
    for (uint32_t a = 0; a < len && !fail; a += 4096u) {   // 2. erase
        wren(); addr_cmd(0x20, a); cmd(page, 4, 0, 0); wait_ready();
    }
    for (uint32_t a = 0; a < len && !fail; a += 256u) {    // 3. program
        uint32_t n = len - a < 256u ? len - a : 256u;
        for (uint32_t i = 0; i < n; i += 4) {
            uint32_t w = W(PSRAM0 + 4 + a + i);
            page[4 + i] = w; page[5 + i] = w >> 8; page[6 + i] = w >> 16; page[7 + i] = w >> 24;
        }
        wren(); addr_cmd(0x02, a); cmd(page, 4 + n, 0, 0); wait_ready();
    }
    for (uint32_t a = 0; a < len; a += 4)                  // 4. verify
        if (W(FLASH + a) != W(PSRAM0 + 4 + a)) { fail |= 1u << 2; kv("mismatch at", a); break; }
    if (fail & (1u << 7)) put("  fail: timeout\n");
    put("FLASH WRITE"); if (fail) { put(" FAIL "); put_hex(fail); } else { put(" OK "); put_hex(len); } put("\n");
    uart_write_flush();
#ifdef BOOT
    if (!fail) __asm__ volatile("li ra, 0x02000100\n jr %0" :: "r"(0x20000004u));
#endif
    return (int)fail;
}
