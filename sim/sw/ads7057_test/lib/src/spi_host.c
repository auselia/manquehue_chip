// Copyright and related rights waived via CC0.
#include "spi_host.h"
#include "util.h"

void spi_host_init(void) {
    *reg32(USER_SPI_HOST_BASE, SPI_HOST_CONTROL_OFFSET) = SPI_HOST_CONTROL_SPIEN;
}

void spi_host_configure(uint8_t csid, uint32_t configopts) {
    unsigned int offs = (csid == 0) ? SPI_HOST_CONFIGOPTS0_OFFSET
                                     : SPI_HOST_CONFIGOPTS1_OFFSET;
    *reg32(USER_SPI_HOST_BASE, offs) = configopts;
}

void spi_host_transfer(uint8_t csid, const uint8_t *tx, uint8_t *rx,
                        uint32_t len, int keep_cs) {
    volatile uint8_t *data8 = (volatile uint8_t *)reg32(USER_SPI_HOST_BASE, SPI_HOST_DATA_OFFSET);

    *reg32(USER_SPI_HOST_BASE, SPI_HOST_CSID_OFFSET) = csid;

    // Fill the TX FIFO first -- the byte-write:true DATA window accepts
    // single-byte writes directly, no manual word-packing needed.
    for (uint32_t i = 0; i < len; i++) {
        while (*reg32(USER_SPI_HOST_BASE, SPI_HOST_STATUS_OFFSET) & SPI_HOST_STATUS_TXFULL)
            ;
        *data8 = tx ? tx[i] : 0x00u;
    }

    while (!(*reg32(USER_SPI_HOST_BASE, SPI_HOST_STATUS_OFFSET) & SPI_HOST_STATUS_READY))
        ;
    *reg32(USER_SPI_HOST_BASE, SPI_HOST_COMMAND_OFFSET) =
        SPI_HOST_CMD_DIRECTION_BIDIR | SPI_HOST_CMD_SPEED_STANDARD |
        (keep_cs ? SPI_HOST_CMD_CSAAT : 0u) | SPI_HOST_CMD_LEN(len);

    // Pop RX bytes as they arrive -- same byte-write:true window, read side.
    for (uint32_t i = 0; i < len; i++) {
        while (*reg32(USER_SPI_HOST_BASE, SPI_HOST_STATUS_OFFSET) & SPI_HOST_STATUS_RXEMPTY)
            ;
        uint8_t b = *data8;
        if (rx) rx[i] = b;
    }
}
