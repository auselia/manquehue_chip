// Copyright and related rights waived via CC0.
#include <stddef.h>
#include "ads7057.h"
#include "spi_host.h"

int32_t ads7057_read(uint8_t csid) {
    uint8_t rx[3] = {0, 0, 0};

    // tx=NULL: the ADS7057 has no MOSI pin, so whatever spi_host shifts out
    // on the shared MOSI line (0x00, per spi_host_transfer's tx=NULL
    // behavior) is simply not looked at by the ADC.
    spi_host_transfer(csid, NULL, rx, 3, 0);

    uint32_t raw24 = ((uint32_t)rx[0] << 16) | ((uint32_t)rx[1] << 8) | rx[2];
    // bit 23 = leading 0 (CS-falling-edge placeholder), bits [22:9] = D13..D0,
    // bits [8:0] = trailing zeros / extra clocks beyond the real 18-clock frame.
    uint16_t code14 = (raw24 >> 9) & 0x3FFFu;

    // Sign-extend the 14-bit two's-complement code to 32 bits.
    return (int32_t)((int16_t)(code14 << 2) >> 2);
}
