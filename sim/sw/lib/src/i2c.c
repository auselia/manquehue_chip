// Copyright 2026 Auselia.
// SPDX-License-Identifier: Apache-2.0
//
// Driver of croc's I2C host (apb_i2c). Polling, no interrupts. See i2c.h.
// Author: Nicolás Villegas - Universidad de los Andes, Chile

#include "i2c.h"
#include "util.h"

static inline void i2c_reg_write(int offset, uint32_t value) { *reg32(I2C_BASE_ADDR, offset) = value; }
static inline uint32_t i2c_reg_read(int offset) { return *reg32(I2C_BASE_ADDR, offset); }

void i2c_init_prescaler(uint32_t prescaler) {
    // The prescaler can change only while the core is off
    i2c_reg_write(I2C_CTRL_REG_OFFSET, 0);
    i2c_reg_write(I2C_PRESCALER_REG_OFFSET, prescaler);
    i2c_reg_write(I2C_CTRL_REG_OFFSET, I2C_CTRL_EN);
}

// One command, then wait for its end. Returns I2C_OK, I2C_NACK (if check_ack) or I2C_AL.
static int i2c_command(uint32_t cmd, int check_ack) {
    i2c_reg_write(I2C_CMD_REG_OFFSET, cmd);
    uint32_t status;
    do {
        status = i2c_reg_read(I2C_STATUS_REG_OFFSET);
    } while (status & I2C_STATUS_TIP);
    i2c_reg_write(I2C_CMD_REG_OFFSET, I2C_CMD_IACK);
    if (status & I2C_STATUS_AL) return I2C_AL;
    if (check_ack && (status & I2C_STATUS_RXNACK)) return I2C_NACK;
    return I2C_OK;
}

// Send one byte (with START if start), stop on an error
static int i2c_send(uint8_t byte, int start) {
    i2c_reg_write(I2C_TX_REG_OFFSET, byte);
    return i2c_command(I2C_CMD_WR | (start ? I2C_CMD_STA : 0), 1);
}

static int i2c_stop_with(int result) {
    i2c_command(I2C_CMD_STO, 0);
    return result;
}

int i2c_write(uint8_t addr7, const uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1), 1);
    for (uint32_t i = 0; r == I2C_OK && i < len; i++) r = i2c_send(data[i], 0);
    return i2c_stop_with(r);
}

static int i2c_receive(uint8_t addr7, uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1) | 1, 1);
    for (uint32_t i = 0; r == I2C_OK && i < len; i++) {
        r = i2c_command(I2C_CMD_RD | (i == len - 1 ? I2C_CMD_NACK : 0), 0);
        data[i] = (uint8_t)i2c_reg_read(I2C_RX_REG_OFFSET);
    }
    return r;
}

int i2c_read(uint8_t addr7, uint8_t *data, uint32_t len) { return i2c_stop_with(i2c_receive(addr7, data, len)); }

int i2c_write_reg(uint8_t addr7, uint8_t reg, const uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1), 1);
    if (r == I2C_OK) r = i2c_send(reg, 0);
    for (uint32_t i = 0; r == I2C_OK && i < len; i++) r = i2c_send(data[i], 0);
    return i2c_stop_with(r);
}

int i2c_read_reg(uint8_t addr7, uint8_t reg, uint8_t *data, uint32_t len) {
    int r = i2c_send((uint8_t)(addr7 << 1), 1);
    if (r == I2C_OK) r = i2c_send(reg, 0);
    if (r == I2C_OK) r = i2c_receive(addr7, data, len); // repeated START
    return i2c_stop_with(r);
}
