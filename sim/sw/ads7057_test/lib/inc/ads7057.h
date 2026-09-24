// Copyright and related rights waived via CC0.
//
// Driver for the ADS7057 (14-bit, 2.5-MSPS, differential SAR ADC) over
// obi_spi_host (see spi_host.h). Unlike the MCP3008 bring-up part, the
// ADS7057 has no MOSI pin and no command/register protocol at all -- CS
// falling *is* the sample trigger, and the result comes back pipelined by
// exactly one frame (this frame's SDO data is last frame's conversion).
// See rtl/obi_spi/README.md and the ADS7057 datasheet (SBAS821) section 8.4
// for the full ACQ/CNV state model this is driving.
#pragma once

#include <stdint.h>

// SPI Mode 1 (CPOL=0, CPHA=1): the ADS7057 launches new SDO data shortly
// after SCLK's rising edge (t_d_CKDO in the datasheet's switching
// characteristics), so the host must sample on the falling edge -- CPHA=1
// gives that. CPHA=0 (the naive guess from just looking at a timing
// diagram) would sample one half-cycle too early.
#define ADS7057_CONFIGOPTS(clkdiv) \
    (SPI_HOST_CFG_CPHA | SPI_HOST_CFG_CLKDIV(clkdiv) | \
     SPI_HOST_CFG_CSNLEAD(2) | SPI_HOST_CFG_CSNTRAIL(2) | SPI_HOST_CFG_CSNIDLE(2))

/// Read one sample. `csid` is whichever chip-select the pinmux routes to
/// the ADS7057's CS pin (CS0 in the current pinmux scheme -- see
/// pinmux.h). Returns the *previous* frame's conversion result, sign
/// extended from the 14-bit two's-complement code -- see the "pipelined
/// output" note below before trusting the very first call.
///
/// spi_host is byte-granular only (COMMAND.LEN counts bytes), so this
/// reads 3 bytes = 24 SCLK clocks rather than the ADS7057's "true" 18-clock
/// frame. The datasheet only assigns special meaning to *exactly* 24
/// clocks (offset calibration, but only on the very first frame after
/// power-up) and *exactly* 64 (recalibration mid-operation); anything else
/// past 18 just harmlessly starts and aborts a recalibration attempt after
/// the real 14-bit result is already shifted out in the first 18 clocks.
/// That's read from the datasheet's state-transition description, not
/// something it states outright for clock counts between 19 and 63 -- treat
/// it as needing bench confirmation on real hardware, not a guarantee.
///
/// Pipelined output: the code returned by call N is the conversion that was
/// running *during* call N-1 (CS falling triggers acquisition of the next
/// sample while shifting out the previous one). Discard the very first
/// read after enabling the SPI path -- it reflects whatever the ADC
/// happened to be converting before firmware ever intended to talk to it,
/// not a defined value.
int32_t ads7057_read(uint8_t csid);
