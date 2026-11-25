// Copyright 2026 Auselia.
// SPDX-License-Identifier: Apache-2.0
//
// I2C host test against the testbench I2C target (a register-pointer device at I2C_TB_ADDR), at 100 and 400 kHz.
// main returns 0, or the number of the first failed check: 1x at 100 kHz, 2x at 400 kHz.
// Author: Nicolás Villegas - Universidad de los Andes, Chile

#include "uart.h"
#include "print.h"
#include "util.h"
#include "config.h"
#include "i2c.h"

#define I2C_TB_ADDR 0x50 // address of the testbench I2C target

// At the current speed: write 4 bytes from register 0x10, read them back with a repeated START, then a wrong address.
// Returns 0, or base + the number of the failed check.
static int test_transfers(int base) {
    const uint8_t pattern[4] = {0xA5, 0x5A, 0x00, 0xFF};
    uint8_t back[4]          = {0, 0, 0, 0};

    CHECK_ASSERT(base + 1, i2c_write_reg(I2C_TB_ADDR, 0x10, pattern, 4) == I2C_OK);
    CHECK_ASSERT(base + 2, i2c_read_reg(I2C_TB_ADDR, 0x10, back, 4) == I2C_OK);
    for (int i = 0; i < 4; i++) CHECK_ASSERT(base + 3, back[i] == pattern[i]);
    CHECK_ASSERT(base + 4, i2c_write(I2C_TB_ADDR + 1, pattern, 1) == I2C_NACK);
    return 0;
}

int main() {
    uart_init();
    i2c_init(100000); // constant speeds: the compiler computes the prescaler
    int r = test_transfers(10);
    if (r == 0) {
        i2c_init(400000);
        r = test_transfers(20);
    }
    if (r == 0) printf("I2C OK\n");
    else printf("I2C FAIL check %x\n", r);
    uart_write_flush();
    return r;
}
