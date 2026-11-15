// Wire bridge: the SX1262 of the Heltec WiFi LoRa 32 V3 is wired to ESP32-S3 GPIO8..14 only (not on the headers).
// This firmware copies croc's radio lines from header J3 to the SX1262 and back, in a loop, so croc drives the radio
// itself. No radio code runs here. croc keeps its SPI clock slow (SX_CLKDIV in sx1262.h) so the copy delay and the
// loop gaps stay far below an SCLK half period.
//
//   croc (ZedBoard)      header J3       SX1262
//   JB3  SCK      ->     GPIO4 (pin 15)  -> GPIO9  SCK
//   JB4  MOSI     ->     GPIO5 (pin 16)  -> GPIO10 MOSI
//   JB8  NSS      ->     GPIO6 (pin 17)  -> GPIO8  NSS
//   JB9  RESET    ->     GPIO7 (pin 18)  -> GPIO12 NRESET
//   JB7  MISO     <-     GPIO3 (pin 14)  <- GPIO11 MISO
//   JB10 DIO0     <-     GPIO2 (pin 13)  <- GPIO13 BUSY
//   GND           --     GND   (pin 1)
//
// All pins are below 32, so one read of GPIO_IN_REG and one write of GPIO_OUT_REG move all six lines at once.
#include <Arduino.h>
#include "soc/gpio_reg.h"
#include <U8g2lib.h>
#include "esp_task_wdt.h"

// OLED (SSD1306 128x64): SDA GPIO17, SCL GPIO18, RST GPIO21, power through Vext (GPIO36 low). Written once in setup:
// the I2C peripheral drives SDA/SCL through the GPIO matrix, so the copy loop does not touch it.
static const int OLED_SDA = 17, OLED_SCL = 18, OLED_RST = 21, VEXT = 36;
U8G2_SSD1306_128X64_NONAME_F_HW_I2C oled(U8G2_R0, OLED_RST, OLED_SCL, OLED_SDA);

static const int IN_SCK = 4, IN_MOSI = 5, IN_NSS = 6, IN_RST = 7;      // from croc
static const int OUT_MISO = 3, OUT_BUSY = 2;                           // to croc
static const int SX_NSS = 8, SX_SCK = 9, SX_MOSI = 10, SX_MISO = 11, SX_RST = 12, SX_BUSY = 13;

// ---- Monitor on core 0: listens to the same lines and decodes croc's SX1262 commands for the OLED. ----
// It only reads GPIO_IN_REG, so the copy loop on core 1 runs exactly as before. SPI mode 0: MOSI and MISO are
// sampled on the SCK rising edge, a frame is NSS low to NSS high. The OLED is redrawn only after 100 ms with no
// SPI activity (an I2C redraw takes about 25 ms and the monitor would miss frames during it). Counts only: a missed
// frame changes the screen, never the bridge.
struct Mon {
  uint32_t frames = 0, resets = 0, settx = 0, txdone = 0, timeouts = 0, wbuf_len = 0, air_ms = 0;
  uint16_t sync = 0;
  uint8_t last_op = 0, payload[4] = {0};
  bool tx_pending = false;
  uint32_t tx_t0 = 0;
} mon;

static void draw() {
  char s[32];
  oled.clearBuffer();
  oled.setFont(u8g2_font_6x10_tf);
  oled.drawStr(0, 9, "croc SX1262 bridge");
  oled.drawHLine(0, 11, 128);
  snprintf(s, sizeof s, "frames %lu  rst %lu", (unsigned long)mon.frames, (unsigned long)mon.resets); oled.drawStr(0, 22, s);
  snprintf(s, sizeof s, "sync %04x  op %02x", mon.sync, mon.last_op); oled.drawStr(0, 32, s);
  snprintf(s, sizeof s, "TX %lu done %lu tmo %lu", (unsigned long)mon.settx, (unsigned long)mon.txdone, (unsigned long)mon.timeouts); oled.drawStr(0, 42, s);
  if (mon.wbuf_len && mon.payload[0] == 'L')
    snprintf(s, sizeof s, "pkt L seq %u  %lu B", mon.payload[1], (unsigned long)mon.wbuf_len);
  else if (mon.wbuf_len && mon.payload[0] == 'E')
    snprintf(s, sizeof s, "pkt E event %u  %lu B", mon.payload[1], (unsigned long)mon.wbuf_len);
  else
    snprintf(s, sizeof s, "pkt %lu B", (unsigned long)mon.wbuf_len);
  oled.drawStr(0, 52, s);
  snprintf(s, sizeof s, "airtime %lu ms", (unsigned long)mon.air_ms); oled.drawStr(0, 62, s);
  oled.sendBuffer();
}

static void frame_end(const uint8_t *mo, const uint8_t *mi, uint32_t n) {
  if (!n) return;
  mon.frames++;
  uint8_t op = mo[0];
  mon.last_op = op;
  if (op == 0x83) { mon.settx++; mon.tx_pending = true; mon.tx_t0 = millis(); }          // SetTx
  else if (op == 0x0E && n >= 3 && mo[1] == 0x00) {                                     // WriteBuffer at 0: payload
    mon.wbuf_len = n - 2;
    for (int i = 0; i < 4; i++) mon.payload[i] = (2 + i < (int)n) ? mo[2 + i] : 0;
  } else if (op == 0x12 && n >= 4) {                                                    // GetIrqStatus
    uint16_t irq = (uint16_t)((mi[2] << 8) | mi[3]);
    if (mon.tx_pending && (irq & 0x0001)) { mon.txdone++; mon.air_ms = millis() - mon.tx_t0; mon.tx_pending = false; }
    if (mon.tx_pending && (irq & 0x0200)) { mon.timeouts++; mon.tx_pending = false; }
  } else if (op == 0x1D && n >= 6 && mo[1] == 0x07 && mo[2] == 0x40) {                  // ReadRegister 0x0740
    mon.sync = (uint16_t)((mi[4] << 8) | mi[5]);
  }
}

static void monitor(void *) {
  static uint8_t mo[80], mi[80];
  uint32_t n = 0, bit = 0, bm = 0, bi = 0, last_act = millis();
  bool dirty = true;
  uint32_t prev = REG_READ(GPIO_IN_REG), edges[4] = {0}, t_rep = millis();
  const int pins[4] = {IN_SCK, IN_MOSI, IN_NSS, IN_RST};
  for (;;) {
    uint32_t in = REG_READ(GPIO_IN_REG);
    uint32_t ch = in ^ prev;
    if (ch) {
      for (int k = 0; k < 4; k++) edges[k] += (ch >> pins[k]) & 1u;
      bool nss = (in >> IN_NSS) & 1u;
      if ((ch >> IN_NSS) & 1u) {
        if (!nss) { n = 0; bit = 0; bm = 0; bi = 0; }                                  // frame start
        else { frame_end(mo, mi, n); dirty = true; }                                   // frame end
      }
      if (((ch >> IN_SCK) & 1u) && ((in >> IN_SCK) & 1u) && !nss) {                    // SCK rising in a frame
        bm = (bm << 1) | ((in >> IN_MOSI) & 1u);
        bi = (bi << 1) | ((in >> SX_MISO) & 1u);
        if (++bit == 8) { if (n < sizeof mo) { mo[n] = (uint8_t)bm; mi[n] = (uint8_t)bi; } n++; bit = 0; bm = 0; bi = 0; }
      }
      if (((ch >> IN_RST) & 1u) && !((in >> IN_RST) & 1u)) { mon.resets++; dirty = true; }  // croc pulls RESET low
      last_act = millis();
      prev = in;
    } else if (millis() - t_rep > 1000) {
      // pin report on USB serial, once a second when the bus is quiet: level and edge count of each croc input
      t_rep = millis();
      if (millis() - last_act > 100)
        Serial.printf("pins SCK=%lu/%lu MOSI=%lu/%lu NSS=%lu/%lu RST=%lu/%lu BUSY=%lu frames=%lu sync=%04x tx=%lu done=%lu\n",
          (unsigned long)((in >> IN_SCK) & 1u), (unsigned long)edges[0], (unsigned long)((in >> IN_MOSI) & 1u), (unsigned long)edges[1],
          (unsigned long)((in >> IN_NSS) & 1u), (unsigned long)edges[2], (unsigned long)((in >> IN_RST) & 1u), (unsigned long)edges[3],
          (unsigned long)((in >> SX_BUSY) & 1u), (unsigned long)mon.frames, mon.sync, (unsigned long)mon.settx, (unsigned long)mon.txdone);
    } else if (dirty && millis() - last_act > 100) {
      draw(); dirty = false;
      prev = REG_READ(GPIO_IN_REG);
    }
  }
}

void setup() {
  Serial.begin(115200);
  // radio side: outputs idle with the radio held in reset until croc releases RESET
  pinMode(SX_NSS, OUTPUT); digitalWrite(SX_NSS, HIGH);
  pinMode(SX_SCK, OUTPUT); digitalWrite(SX_SCK, LOW);
  pinMode(SX_MOSI, OUTPUT); digitalWrite(SX_MOSI, LOW);
  pinMode(SX_RST, OUTPUT); digitalWrite(SX_RST, LOW);
  pinMode(SX_MISO, INPUT);
  pinMode(SX_BUSY, INPUT);
  // croc side
  pinMode(IN_SCK, INPUT); pinMode(IN_MOSI, INPUT); pinMode(IN_NSS, INPUT_PULLUP); pinMode(IN_RST, INPUT_PULLDOWN);
  pinMode(OUT_MISO, OUTPUT); pinMode(OUT_BUSY, OUTPUT);
  pinMode(VEXT, OUTPUT); digitalWrite(VEXT, LOW); delay(50);
  oled.begin();
  draw();
  delay(200);
  Serial.println("croc SX1262 bridge: J3 GPIO4 SCK, 5 MOSI, 6 NSS, 7 RST in; GPIO3 MISO, 2 BUSY out");
  Serial.flush();
  disableCore0WDT();                                       // the monitor never yields on core 0
  xTaskCreatePinnedToCore(monitor, "monitor", 4096, nullptr, 1, nullptr, 0);
}

void loop() {
  // Never returns: no Serial, no delay, no yield in here.
  const uint32_t keep = ~((1u << SX_NSS) | (1u << SX_SCK) | (1u << SX_MOSI) | (1u << SX_RST) | (1u << OUT_MISO) | (1u << OUT_BUSY));
  uint32_t base = REG_READ(GPIO_OUT_REG) & keep;
  for (;;) {
    uint32_t in = REG_READ(GPIO_IN_REG);
    uint32_t out = base
      | (((in >> IN_SCK) & 1u) << SX_SCK)
      | (((in >> IN_MOSI) & 1u) << SX_MOSI)
      | (((in >> IN_NSS) & 1u) << SX_NSS)
      | (((in >> IN_RST) & 1u) << SX_RST)
      | (((in >> SX_MISO) & 1u) << OUT_MISO)
      | (((in >> SX_BUSY) & 1u) << OUT_BUSY);
    REG_WRITE(GPIO_OUT_REG, out);
  }
}
