// Copyright and related rights waived via CC0.
//
// Minimal driver for obi_spi_host (OpenTitan spi_host over the OBI<->TL-UL
// bridge -- see rtl/obi_spi/README.md). Register offsets and bit-field
// positions are taken directly from the source hjson this build was
// generated from (hw/ip/spi_host/data/spi_host.hjson, tag
// earlgrey_silver_release_v3, NumCS=2 -- see rtl/obi_spi/README.md for the
// regen story), not reverse-engineered from the generated RTL.
//
// This only implements standard (single-lane), full-duplex, byte-oriented
// transfers -- everything both the SX1276 and the MCP3008 need. Dual/quad
// speed and read-only/write-only segments aren't exposed here since nothing
// in this bring-up uses them.
#pragma once

#include <stdint.h>
#include "config.h"

// ---- Register offsets (from USER_SPI_HOST_BASE) ----
#define SPI_HOST_INTR_STATE_OFFSET   0x00
#define SPI_HOST_INTR_ENABLE_OFFSET  0x04
#define SPI_HOST_INTR_TEST_OFFSET    0x08
#define SPI_HOST_CONTROL_OFFSET      0x0c
#define SPI_HOST_STATUS_OFFSET       0x10
#define SPI_HOST_CONFIGOPTS0_OFFSET  0x14
#define SPI_HOST_CONFIGOPTS1_OFFSET  0x18
#define SPI_HOST_CSID_OFFSET         0x1c
#define SPI_HOST_COMMAND_OFFSET      0x20
#define SPI_HOST_DATA_OFFSET         0x24  // TX push on write, RX pop on read
#define SPI_HOST_ERROR_ENABLE_OFFSET 0x28
#define SPI_HOST_ERROR_STATUS_OFFSET 0x2c
#define SPI_HOST_EVENT_ENABLE_OFFSET 0x30

// ---- CONTROL bits ----
#define SPI_HOST_CONTROL_SPIEN    (1u << 31)
#define SPI_HOST_CONTROL_SW_RST   (1u << 30)

// ---- STATUS bits ----
#define SPI_HOST_STATUS_READY   (1u << 31)
#define SPI_HOST_STATUS_ACTIVE  (1u << 30)
#define SPI_HOST_STATUS_TXFULL  (1u << 29)
#define SPI_HOST_STATUS_TXEMPTY (1u << 28)
#define SPI_HOST_STATUS_RXFULL  (1u << 25)
#define SPI_HOST_STATUS_RXEMPTY (1u << 24)

// ---- CONFIGOPTS_n fields (per chip-select, one register per CSID) ----
#define SPI_HOST_CFG_CPOL          (1u << 31)
#define SPI_HOST_CFG_CPHA          (1u << 30)
#define SPI_HOST_CFG_FULLCYC       (1u << 29)
#define SPI_HOST_CFG_CSNLEAD(x)    (((uint32_t)(x) & 0xFu) << 24)
#define SPI_HOST_CFG_CSNTRAIL(x)   (((uint32_t)(x) & 0xFu) << 20)
#define SPI_HOST_CFG_CSNIDLE(x)    (((uint32_t)(x) & 0xFu) << 16)
#define SPI_HOST_CFG_CLKDIV(x)     ((uint32_t)(x) & 0xFFFFu)

// ---- COMMAND fields ----
// DIRECTION: 0=dummy (no TX/RX), 1=RX only, 2=TX only, 3=bidirectional
#define SPI_HOST_CMD_DIRECTION(x)  (((uint32_t)(x) & 0x3u) << 12)
#define SPI_HOST_CMD_DIRECTION_BIDIR SPI_HOST_CMD_DIRECTION(3)
// SPEED: 0=Standard SPI (the only one this driver uses)
#define SPI_HOST_CMD_SPEED_STANDARD (0u << 10)
// CSAAT: keep chip-select asserted after this segment (multi-segment transfers)
#define SPI_HOST_CMD_CSAAT         (1u << 9)
// LEN: number of bytes in this segment, MINUS ONE (0 = 1 byte)
#define SPI_HOST_CMD_LEN(n_bytes)  (((uint32_t)(n_bytes) - 1u) & 0x1FFu)

/// Enable the SPI host (CONTROL.SPIEN). Call once before any transfer.
void spi_host_init(void);

/// Program CONFIGOPTS_<csid> (clock divider, CPOL/CPHA, CS timing) for one
/// chip-select. Build `configopts` from the SPI_HOST_CFG_* macros above.
void spi_host_configure(uint8_t csid, uint32_t configopts);

/// Full-duplex byte transfer on the given chip-select. `tx` may be NULL
/// (0x00 is shifted out); `rx` may be NULL (received bytes are discarded).
/// `keep_cs`: leave chip-select asserted after this call (for a later
/// call that continues the same transaction) instead of deasserting it.
void spi_host_transfer(uint8_t csid, const uint8_t *tx, uint8_t *rx,
                        uint32_t len, int keep_cs);
