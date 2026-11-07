// Step 4, LoRa standalone (SX1276 on Pmod JB3..JB10): RegVersion = 0x12, then NPKT packets of 8 bytes, one per
// second, each with TxDone on DIO0 (LD6 flashes). Packet: 'L', sequence, 6 bytes 0xA5 5A C3 3C 0F F0.
// Receiver: 915 MHz, LoRa SF7, BW 125 kHz, CR 4/5, explicit header, CRC on, sync word 0x12.
#include "bringup.h"
static uint8_t pkt[9] = {0x80, 'L', 0, 0xA5, 0x5A, 0xC3, 0x3C, 0x0F, 0xF0};
int main() {
    uart_init();
    put("STEP4 lora\n");
    uint8_t ver = rf_init(8);
    kv("radio version", ver);
    check(0, ver == 0x12, "radio version");
    for (uint32_t i = 0; i < NPKT && !(fail & 1u); i++) {
        pkt[2] = (uint8_t)i;
        uint32_t a = rf_send(pkt, 8);
        kv("tx airtime", a);
        if (!a) fail |= 1u << 1;
        wait_cycles(CLK_HZ);
    }
    check(1, !(fail & 2u), "no TxDone on DIO0");
    check(2, !(fail & (1u << 30)), "spi timeout");
    check(3, SPI(RF_ERR) == 0u, "rf_spi error");
    return finish("STEP4");
}
