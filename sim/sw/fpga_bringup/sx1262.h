// SX1262 LoRa driver for croc (rf_spi on the shared SPI bus), included after bringup.h.
// Pins: SCK, MOSI, MISO, NSS (CS1) and NRESET (RF_PINS[0]) as for the SX1276. BUSY on the DIO0 input (RF_PINS[8]).
// DIO1 is not used: TxDone is polled with GetIrqStatus. So the chip needs no new pad for the SX1262.
// Settings: SX_FRF (default 915 MHz), SF7, BW 125 kHz, CR 4/5, explicit header, CRC on, preamble 8, sync word 0x12,
// +14 dBm. Board: TCXO 1.8 V on DIO3 and RF switch on DIO2 (Heltec WiFi LoRa 32 V3, most SX1262 modules).
// On the ZedBoard the SX1262 is reached through the Heltec wire bridge (heltec/bridge), so SCLK is slow: SX_CLKDIV.
#ifndef SX_CLKDIV
#define SX_CLKDIV 199u                                     // SCLK = 20 MHz / (2 x 200) = 50 kHz through the bridge
#endif
#ifndef SX_FRF
#define SX_FRF 0x39300000u                                 // 915 MHz x 2^25 / 32 MHz. 868 MHz 0x36400000
#endif
#ifndef SX_CALIMG
#define SX_CALIMG 0xE1u, 0xE9u                             // CalibrateImage 902 to 928 MHz. 863 to 870: 0xD7, 0xDB
#endif
#define SX_FAIL_BUSY (1u << 4)
#ifndef CROC_HAVE_MEMSET
#define CROC_HAVE_MEMSET
// no C library on croc: the compiler calls memset for array clears
void *memset(void *d, int c, unsigned n) { uint8_t *p = d; while (n--) *p++ = (uint8_t)c; return d; }
#endif

static int sx_busy(void) { return (int)((SPI(RF_PINS) >> 8) & 1u); }
// BUSY goes high a few hundred ns after NSS rises, a few us later through the bridge: wait before looking at it
static void sx_wait_busy(void) {
    wait_cycles(CLK_HZ / 25000u);                          // 40 us
    uint32_t t = mcycle();
    while (sx_busy()) if (mcycle() - t > TIMEOUT) { fail |= SX_FAIL_BUSY; return; }
}
static void sx_cmd(const uint8_t *tx, uint8_t *rx, uint32_t n) { sx_wait_busy(); rf_xfer(tx, rx, n); }

// command list: length, then the bytes. Order as in Semtech's SX1261/2 datasheet section 14.
static const uint8_t sx_cfg[] = {
    2, 0x80, 0x00,                                         // SetStandby STDBY_RC
    5, 0x97, 0x02, 0x00, 0x01, 0x40,                       // SetDIO3AsTCXOCtrl 1.8 V, 320 x 15.625 us = 5 ms
    2, 0x89, 0x7F,                                         // Calibrate all blocks (with the TCXO on)
    2, 0x9D, 0x01,                                         // SetDIO2AsRfSwitchCtrl
    2, 0x96, 0x01,                                         // SetRegulatorMode DC-DC
    2, 0x8A, 0x01,                                         // SetPacketType LoRa
    5, 0x86, (SX_FRF >> 24) & 0xFF, (SX_FRF >> 16) & 0xFF, (SX_FRF >> 8) & 0xFF, SX_FRF & 0xFF,   // SetRfFrequency
    3, 0x98, SX_CALIMG,                                    // CalibrateImage
    5, 0x95, 0x02, 0x02, 0x00, 0x01,                       // SetPaConfig: SX1262 table for +14 dBm
    3, 0x8E, 0x0E, 0x04,                                   // SetTxParams +14 dBm, ramp 200 us
    3, 0x8F, 0x00, 0x00,                                   // SetBufferBaseAddress TX 0, RX 0
    9, 0x8B, 0x07, 0x04, 0x01, 0x00, 0, 0, 0, 0,           // SetModulationParams SF7, BW 125 kHz, CR 4/5, LDRO off
    5, 0x0D, 0x07, 0x40, 0x14, 0x24,                       // WriteRegister 0x0740: sync word 0x1424 (= 0x12)
    9, 0x08, 0x02, 0x01, 0x02, 0x01, 0, 0, 0, 0,           // SetDioIrqParams: TxDone, Timeout (also to DIO1)
    3, 0x02, 0xFF, 0xFF,                                   // ClearIrqStatus
    0
};

static uint16_t sx_read_reg16(uint16_t a) {
    uint8_t tx[6] = {0x1D, (uint8_t)(a >> 8), (uint8_t)a, 0, 0, 0}, rx[6] = {0};
    sx_cmd(tx, rx, 6);
    return (uint16_t)((rx[4] << 8) | rx[5]);
}
static uint8_t sx_status(void) { uint8_t tx[2] = {0xC0, 0}, rx[2] = {0}; sx_cmd(tx, rx, 2); return rx[1]; }

// Reset, configure. Returns the sync word read back (0x1424 when the radio answers and keeps what it was told).
static uint16_t sx_init(void) {
    SPI(RF_CTRL) = 1u | (SX_CLKDIV << 8) | (1u << 16);     // EN, mode 0, CS_SETUP 1 half period
    SPI(RF_PINS) = 0u; wait_cycles(CLK_HZ / 1000);         // NRESET low 1 ms
    SPI(RF_PINS) = 1u; wait_cycles(CLK_HZ / 200);          // 5 ms, then BUSY low when ready
    for (uint32_t i = 0; sx_cfg[i]; i += sx_cfg[i] + 1u) sx_cmd(&sx_cfg[i + 1], 0, sx_cfg[i]);
    return sx_read_reg16(0x0740);
}

// Writes len bytes at buffer offset 0x80 and reads them back: errors counted (checks the SPI path, the bridge).
static uint32_t sx_buffer_check(uint32_t len, uint8_t seed) {
    uint8_t tx[2 + 64], rx[3 + 64];
    if (len > 64u) len = 64u;
    tx[0] = 0x0E; tx[1] = 0x80;
    for (uint32_t i = 0; i < len; i++) tx[2 + i] = (uint8_t)(seed + 37u * i);
    sx_cmd(tx, 0, 2 + len);
    uint8_t rq[3 + 64] = {0x1E, 0x80, 0};
    sx_cmd(rq, rx, 3 + len);
    uint32_t err = 0;
    for (uint32_t i = 0; i < len; i++) if (rx[3 + i] != tx[2 + i]) err++;
    return err;
}

// Sends len payload bytes (at most 64). Returns the airtime in cycles (SetTx to TxDone), 0 on timeout.
static uint32_t sx_send(const uint8_t *p, uint32_t len) {
    uint8_t b[2 + 64];
    if (len > 64u) len = 64u;
    b[0] = 0x0E; b[1] = 0x00;                              // WriteBuffer at offset 0
    for (uint32_t i = 0; i < len; i++) b[2 + i] = p[i];
    sx_cmd(b, 0, 2 + len);
    const uint8_t pp[10] = {0x8C, 0x00, 0x08, 0x00, (uint8_t)len, 0x01, 0x00, 0, 0, 0};   // SetPacketParams
    sx_cmd(pp, 0, 10);
    const uint8_t clr[3] = {0x02, 0xFF, 0xFF};
    sx_cmd(clr, 0, 3);
    const uint8_t tx[4] = {0x83, 0x00, 0x00, 0x00};        // SetTx, no timeout
    sx_cmd(tx, 0, 4);
    uint32_t t = mcycle();
    for (;;) {
        uint8_t q[4] = {0x12, 0, 0, 0}, r[4] = {0};
        sx_cmd(q, r, 4);
        uint16_t irq = (uint16_t)((r[2] << 8) | r[3]);
        if (irq & 0x0001u) break;                          // TxDone
        if ((irq & 0x0200u) || mcycle() - t > TIMEOUT) return 0;
    }
    t = mcycle() - t;
    sx_cmd(clr, 0, 3);
    return t;
}
