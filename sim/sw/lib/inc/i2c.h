// Copyright 2026 Auselia.
// SPDX-License-Identifier: Apache-2.0
//
// Driver of croc's I2C host (apb_i2c, the OpenCores I2C master) at I2C_BASE_ADDR. Polling, no interrupts.
// Author: Nicolás Villegas - Universidad de los Andes, Chile
//
// Header only (static inline): a program that does not use I2C gets no code from it. Every program links all of the
// library, and the SRAM is 2 KB.
// The core ignores byte strobes: write its registers only as full 32-bit words (reg32), never with sb or sh.

#pragma once

#include <stdint.h>
#include "config.h"
#include "util.h"

#define I2C_PRESCALER_REG_OFFSET 0x00 // SCL = f_clk / (5 * (prescaler + 1))
#define I2C_CTRL_REG_OFFSET      0x04
#define I2C_RX_REG_OFFSET        0x08
#define I2C_STATUS_REG_OFFSET    0x0C
#define I2C_TX_REG_OFFSET        0x10
#define I2C_CMD_REG_OFFSET       0x14

#define I2C_CTRL_EN  (1 << 7) // core enable
#define I2C_CTRL_IEN (1 << 6) // interrupt enable

#define I2C_CMD_STA  (1 << 7) // (repeated) start
#define I2C_CMD_STO  (1 << 6) // stop
#define I2C_CMD_RD   (1 << 5) // read a byte
#define I2C_CMD_WR   (1 << 4) // write the TX byte
#define I2C_CMD_NACK (1 << 3) // on a read: answer NACK (the last byte)
#define I2C_CMD_IACK (1 << 0) // clear the interrupt flag

#define I2C_STATUS_RXNACK (1 << 7) // the target did not acknowledge
#define I2C_STATUS_BUSY   (1 << 6) // a start was seen, no stop yet
#define I2C_STATUS_AL     (1 << 5) // arbitration lost
#define I2C_STATUS_TIP    (1 << 1) // transfer in progress
#define I2C_STATUS_IF     (1 << 0) // interrupt flag

// return values
#define I2C_OK    0
#define I2C_NACK -1 // no acknowledge from the target (wrong address, or it refused a byte)
#define I2C_AL   -2 // arbitration lost (another host on the bus)

// The prescaler for an SCL frequency, computed by the compiler (rv32i has no divide instruction)
#define I2C_PRESCALER(scl_hz) (I2C_FREQ / (5 * (scl_hz)) - 1)

// Enable the core with SCL at scl_hz (100000 or 400000), a constant. Call it again to change the speed.
#define i2c_init(scl_hz) i2c_init_prescaler(I2C_PRESCALER(scl_hz))

static inline void i2c_init_prescaler(uint32_t prescaler) {
    // The prescaler can change only while the core is off
    *reg32(I2C_BASE_ADDR, I2C_CTRL_REG_OFFSET)      = 0;
    *reg32(I2C_BASE_ADDR, I2C_PRESCALER_REG_OFFSET) = prescaler;
    *reg32(I2C_BASE_ADDR, I2C_CTRL_REG_OFFSET)      = I2C_CTRL_EN;
}

// One command, then wait for its end. Returns I2C_OK, I2C_NACK (if check_ack) or I2C_AL.
static inline int i2c_command(uint32_t cmd, int check_ack) {
    *reg32(I2C_BASE_ADDR, I2C_CMD_REG_OFFSET) = cmd;
    uint32_t status;
    do {
        status = *reg32(I2C_BASE_ADDR, I2C_STATUS_REG_OFFSET);
    } while (status & I2C_STATUS_TIP);
    *reg32(I2C_BASE_ADDR, I2C_CMD_REG_OFFSET) = I2C_CMD_IACK;
    if (status & I2C_STATUS_AL) return I2C_AL;
    if (check_ack && (status & I2C_STATUS_RXNACK)) return I2C_NACK;
    return I2C_OK;
}

// Send one byte, with a (repeated) START before it if start
static inline int i2c_send(uint8_t byte, int start) {
    *reg32(I2C_BASE_ADDR, I2C_TX_REG_OFFSET) = byte;
    return i2c_command(I2C_CMD_WR | (start ? I2C_CMD_STA : 0), 1);
}

// STOP, then wait until the STOP is on the bus. TIP covers only reads and writes, not a STOP: a command written
// before the STOP ends merges with it, and the next START comes out with SDA and SCL falling together. BUSY (a START
// was seen, no STOP yet) clears when the STOP condition is on the bus.
static inline int i2c_stop_with(int result) {
    *reg32(I2C_BASE_ADDR, I2C_CMD_REG_OFFSET) = I2C_CMD_STO;
    while (*reg32(I2C_BASE_ADDR, I2C_STATUS_REG_OFFSET) & I2C_STATUS_BUSY)
        ;
    *reg32(I2C_BASE_ADDR, I2C_CMD_REG_OFFSET) = I2C_CMD_IACK;
    return result;
}

// Read len bytes after the address byte: the last byte gets a NACK. No STOP.
static inline int i2c_receive(uint8_t addr7, uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1) | 1, 1);
    for (uint32_t i = 0; r == I2C_OK && i < len; i++) {
        r       = i2c_command(I2C_CMD_RD | (i == len - 1 ? I2C_CMD_NACK : 0), 0);
        data[i] = (uint8_t)*reg32(I2C_BASE_ADDR, I2C_RX_REG_OFFSET);
    }
    return r;
}

// Write len bytes to the target at addr7 (7-bit address), then STOP
static inline int i2c_write(uint8_t addr7, const uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1), 1);
    for (uint32_t i = 0; r == I2C_OK && i < len; i++) r = i2c_send(data[i], 0);
    return i2c_stop_with(r);
}

// Read len bytes from the target at addr7, then STOP
static inline int i2c_read(uint8_t addr7, uint8_t *data, uint32_t len) {
    return i2c_stop_with(i2c_receive(addr7, data, len));
}

// Register access of a typical sensor: the register number, then the data (write) or a repeated START and a read
static inline int i2c_write_reg(uint8_t addr7, uint8_t reg, const uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1), 1);
    if (r == I2C_OK) r = i2c_send(reg, 0);
    for (uint32_t i = 0; r == I2C_OK && i < len; i++) r = i2c_send(data[i], 0);
    return i2c_stop_with(r);
}

static inline int i2c_read_reg(uint8_t addr7, uint8_t reg, uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1), 1);
    if (r == I2C_OK) r = i2c_send(reg, 0);
    if (r == I2C_OK) r = i2c_receive(addr7, data, len);
    return i2c_stop_with(r);
}
