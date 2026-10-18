// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Package of the OBI SPI block (radio SPI master and ADS7057 reader), spec docs/spi_adc_spec.md.
// The register map is not frozen (spec review, AUS-16). This package holds only what does not depend on it:
// the window layout and the pad signals with their idle levels.

package obi_spi_pkg;

  /// The block decodes a 4 KB window. Offsets are relative to the window base.
  localparam int unsigned WindowBits  = 12;
  /// Word address width inside the window
  localparam int unsigned AddrBits    = WindowBits - 2;
  /// Sub-blocks: radio master at 0x000..0x0FF, ADC reader at 0x100..0x1FF, the rest is unmapped
  localparam logic [WindowBits-1:0] RfBase  = 12'h000;
  localparam logic [WindowBits-1:0] AdcBase = 12'h100;
  localparam logic [WindowBits-1:0] MapEnd  = 12'h200;

  /// Pad outputs of the block (spec section 3, pads 19 to 31)
  typedef struct packed {
    logic adc_sclk;     // forwarded system clock, idles high
    logic adc_csn;      // ADC chip select, active low
    logic adc_wake_clr; // clears the WAKE_N latch of the AFE board
    logic adc_cap_en;   // capture chain supply of the AFE board
    logic rf_sclk;      // radio SPI clock, idles at CPOL (0 after reset)
    logic rf_mosi;
    logic rf_csn;       // radio chip select, active low
    logic rf_rstn;      // radio reset, active low
  } spi_pads_out_t;

  /// Pad inputs of the block
  typedef struct packed {
    logic adc_sdo;      // ADC data out
    logic adc_wake_n;   // latched window comparator of the AFE board, active low
    logic adc_big_n;    // large event flag of the AFE board, active low
    logic rf_miso;
    logic rf_dio0;      // radio done or RX interrupt
  } spi_pads_in_t;

  /// Output levels while the blocks are disabled and after reset (spec sections 4 and 5)
  localparam spi_pads_out_t PadsOutIdle = '{
    adc_sclk:     1'b1,
    adc_csn:      1'b1,
    adc_wake_clr: 1'b0,
    adc_cap_en:   1'b1,
    rf_sclk:      1'b0,
    rf_mosi:      1'b0,
    rf_csn:       1'b1,
    rf_rstn:      1'b0
  };

  /// Inactive input levels, used by user_domain to tie the inputs while the pads are not connected.
  /// Unused in the block itself, hence the waiver for the lint of the block alone.
  /* verilator lint_off UNUSEDPARAM */
  localparam spi_pads_in_t PadsInIdle = '{
    adc_sdo:    1'b0,
    adc_wake_n: 1'b1,
    adc_big_n:  1'b1,
    rf_miso:    1'b0,
    rf_dio0:    1'b0
  };
  /* verilator lint_on UNUSEDPARAM */

endpackage
