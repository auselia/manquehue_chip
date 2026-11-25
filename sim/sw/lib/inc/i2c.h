// Copyright 2026 Auselia.
// SPDX-License-Identifier: Apache-2.0
//
// Driver of croc's I2C host (apb_i2c, the OpenCores I2C master) at I2C_BASE_ADDR
// Author: Nicolás Villegas - Universidad de los Andes, Chile
//
// The core ignores byte strobes: write its registers only as full 32-bit words (reg32), never with sb or sh.

#pragma once

#include <stdint.h>
#include "config.h"

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
void i2c_init_prescaler(uint32_t prescaler);

// Write len bytes to the target at addr7 (7-bit address). A STOP ends the transfer.
int i2c_write(uint8_t addr7, const uint8_t *data, uint32_t len);

// Read len bytes from the target at addr7. The last byte gets a NACK, then a STOP.
int i2c_read(uint8_t addr7, uint8_t *data, uint32_t len);

// Register access of a typical sensor: write the register number, repeated START, then write or read len bytes.
int i2c_write_reg(uint8_t addr7, uint8_t reg, const uint8_t *data, uint32_t len);
int i2c_read_reg(uint8_t addr7, uint8_t reg, uint8_t *data, uint32_t len);
