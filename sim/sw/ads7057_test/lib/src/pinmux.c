// Copyright and related rights waived via CC0.
#include "pinmux.h"
#include "util.h"

void pinmux_set(uint32_t sel) {
    *reg32(USER_PINMUX_BASE, 0x0) = sel & 0x7u;
}

uint32_t pinmux_get(void) {
    return *reg32(USER_PINMUX_BASE, 0x0) & 0x7u;
}
