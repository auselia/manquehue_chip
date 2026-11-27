// I2C host test against the I2C target model of the test bench (a register-pointer device at address 0x50), at
// 100 and 400 kHz. It fits the 2 KB SRAM: no UART, the result is the return value of main.
// Author: Nicolás Villegas - Universidad de los Andes, Chile
//
// main returns 0, or the number of the first failed check: 1x at 100 kHz, 2x at 400 kHz.

#include "config.h"
#include "i2c.h"

#define TB_TARGET 0x50 // address of the test bench I2C target

// At the current speed: write 4 bytes from register 0x10, read them back with a repeated START, then a wrong address.
// Returns 0, or base + the number of the failed check.
static int test_transfers(int base) {
    const uint8_t pattern[4] = {0xA5, 0x5A, 0x00, 0xFF};
    uint8_t back[4]          = {0, 0, 0, 0};
    if (i2c_write_reg(TB_TARGET, 0x10, pattern, 4) != I2C_OK) return base + 1;
    if (i2c_read_reg(TB_TARGET, 0x10, back, 4) != I2C_OK) return base + 2;
    for (int i = 0; i < 4; i++)
        if (back[i] != pattern[i]) return base + 3;
    if (i2c_write(TB_TARGET + 1, pattern, 1) != I2C_NACK) return base + 4;
    return 0;
}

int main() {
    i2c_init(100000); // constant speeds: the compiler computes the prescaler
    int r = test_transfers(10);
    if (r == 0) {
        i2c_init(400000);
        r = test_transfers(20);
    }
    return r;
}
