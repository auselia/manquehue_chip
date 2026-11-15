// LoRa receiver for croc (Heltec WiFi LoRa 32 V3, SX1262). Same settings as croc's sx1262.h: 915 MHz, SF7, BW 125 kHz,
// CR 4/5, explicit header, CRC on, sync word 0x12, preamble 8. TCXO 1.8 V on DIO3, DIO2 drives the RF switch
// (Meshtastic heltec_v3 variant).
// One line per packet on USB serial (115200):
//   RX n=<count> len=<bytes> rssi=<dBm> snr=<dB> crc=<ok|bad> hex=<payload>
// then a decoded line for croc's layouts: step 4 ('L', sequence, A5 5A C3 3C 0F F0) and step 8 ('E', event features).
#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

static const int SX_NSS = 8, SX_SCK = 9, SX_MOSI = 10, SX_MISO = 11, SX_RST = 12, SX_BUSY = 13, SX_DIO1 = 14;
SX1262 radio = new Module(SX_NSS, SX_DIO1, SX_RST, SX_BUSY);
static volatile bool got = false;
static uint32_t count = 0;

static void IRAM_ATTR on_rx() { got = true; }
static uint16_t u16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static uint32_t u32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

void setup() {
  Serial.begin(115200);
  delay(500);
  SPI.begin(SX_SCK, SX_MISO, SX_MOSI, SX_NSS);
  int st = radio.begin(915.0, 125.0, 7, 5, RADIOLIB_SX126X_SYNC_WORD_PRIVATE, 14, 8, 1.8, false);
  if (st == RADIOLIB_ERR_NONE) st = radio.setDio2AsRfSwitch(true);
  if (st == RADIOLIB_ERR_NONE) st = radio.setCRC(2);
  radio.setPacketReceivedAction(on_rx);
  if (st == RADIOLIB_ERR_NONE) st = radio.startReceive();
  Serial.printf("croc LoRa receiver: 915 MHz SF7 BW125 CR4/5 sync 0x12, init %s (%d)\n", st == RADIOLIB_ERR_NONE ? "ok" : "FAILED", st);
}

void loop() {
  if (!got) return;
  got = false;
  uint8_t b[256];
  size_t len = radio.getPacketLength();
  int st = radio.readData(b, len);
  count++;
  Serial.printf("RX n=%lu len=%u rssi=%.1f snr=%.2f crc=%s hex=", (unsigned long)count, (unsigned)len, radio.getRSSI(),
                radio.getSNR(), st == RADIOLIB_ERR_NONE ? "ok" : (st == RADIOLIB_ERR_CRC_MISMATCH ? "bad" : "err"));
  for (size_t i = 0; i < len; i++) Serial.printf("%02x", b[i]);
  Serial.println();
  if (st == RADIOLIB_ERR_NONE && len == 8 && b[0] == 'L') {
    bool pat = b[2] == 0xA5 && b[3] == 0x5A && b[4] == 0xC3 && b[5] == 0x3C && b[6] == 0x0F && b[7] == 0xF0;
    Serial.printf("  step4 seq=%u pattern=%s\n", b[1], pat ? "ok" : "WRONG");
  } else if (st == RADIOLIB_ERR_NONE && len == 34 && b[0] == 'E') {
    Serial.printf("  step8 event=%u mtime=%lu bins=%u,%u,%u,%u status=%02x,%02x,%02x,%02x band=%lu total=%lu "
                  "rise=%u fall=%u duration=%u peak=%u mean=%u crest16=%u onset=%d\n",
                  b[1], (unsigned long)u32(&b[2]), b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
                  (unsigned long)u32(&b[14]), (unsigned long)u32(&b[18]), u16(&b[22]), u16(&b[24]), u16(&b[26]),
                  u16(&b[28]), u16(&b[30]), b[32], (int8_t)b[33]);
  }
  radio.startReceive();
}
