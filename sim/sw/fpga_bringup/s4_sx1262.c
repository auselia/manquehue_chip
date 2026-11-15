// Step 4 with the SX1262 (sx1262.h), from the QSPI flash. On the ZedBoard the radio is the SX1262 of a Heltec WiFi
// LoRa 32 V3, reached through the Heltec wire bridge on Pmod JB (README section 9).
// Checks: the sync word reads back 0x1424 (the radio answers and keeps its settings), 20 buffer write/read-backs of
// 64 bytes with no error (the SPI path), then NPKT packets of 8 bytes, one per second, each with TxDone.
// Packet: 'L', sequence, A5 5A C3 3C 0F F0 (as the SX1276 step 4). Receiver: heltec/receiver.
// FAIL bits: 0 sync word, 1 no TxDone, 2 SPI timeout, 3 rf_spi error, 4 BUSY stuck high, 5 buffer read-back errors.
#include "bringup.h"
#include "sx1262.h"
static uint8_t pkt[8] = {'L', 0, 0xA5, 0x5A, 0xC3, 0x3C, 0x0F, 0xF0};
int main() {
    uart_init();
    put("STEP4 sx1262\n");
    uint16_t sw = sx_init();
    kv("sync word", sw);
    kv("status", sx_status());
    check(0, sw == 0x1424u, "sync word");
    uint32_t err = 0;
    for (uint32_t i = 0; i < 20u && !(fail & 1u); i++) err += sx_buffer_check(64, (uint8_t)(i * 13u));
    kv("buffer errors", err);
    check(5, err == 0u, "buffer read-back");
    for (uint32_t i = 0; i < NPKT && !(fail & 1u); i++) {
        pkt[1] = (uint8_t)i;
        uint32_t a = sx_send(pkt, 8);
        kv("tx airtime", a);
        if (!a) fail |= 1u << 1;
        wait_cycles(CLK_HZ);
    }
    check(1, !(fail & 2u), "no TxDone");
    check(2, !(fail & (1u << 30)), "spi timeout");
    check(3, SPI(RF_ERR) == 0u, "rf_spi error");
    check(4, !(fail & SX_FAIL_BUSY), "BUSY stuck high");
    return finish("STEP4");
}
