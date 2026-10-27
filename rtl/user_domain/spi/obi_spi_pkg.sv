// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Package of the OBI SPI block (radio SPI master and ADS7057 reader on one shared bus), spec docs/spi_adc_spec.md.
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

  /// Pad outputs of the block: one SPI bus shared by the ADS7057 (CS0) and the SX1276 (CS1), plus the radio reset
  typedef struct packed {
    logic sck;          // ADC: forwarded system clock, idles high. Radio: rf_spi SCLK while the radio owns the bus
    logic sd_o;         // radio MOSI (the ADC has no data input)
    logic cs0_n;        // ADC chip select, active low
    logic cs1_n;        // radio chip select, active low
    logic rf_rstn;      // radio reset, active low
  } spi_pads_out_t;

  /// Pad inputs of the block
  typedef struct packed {
    logic sd_i;         // ADC SDO and radio MISO (each is high-Z while its CS is high)
    logic afe_irq_n;    // window comparator of the AFE board (WAKE_N), active low
    logic rf_dio0;      // radio done or RX interrupt
  } spi_pads_in_t;

  /// Output levels while the blocks are disabled and after reset (spec sections 4 and 5). Used by the testbenches,
  /// not by the block itself, hence the waiver for the lint of the block alone.
  /* verilator lint_off UNUSEDPARAM */
  localparam spi_pads_out_t PadsOutIdle = '{
    sck:     1'b1,
    sd_o:    1'b0,
    cs0_n:   1'b1,
    cs1_n:   1'b1,
    rf_rstn: 1'b0
  };
  /* verilator lint_on UNUSEDPARAM */

  /// Inactive input levels, used by user_domain to tie the inputs while the pads are not connected.
  /// Unused in the block itself, hence the waiver for the lint of the block alone.
  /* verilator lint_off UNUSEDPARAM */
  localparam spi_pads_in_t PadsInIdle = '{
    sd_i:      1'b0,
    afe_irq_n: 1'b1,
    rf_dio0:   1'b0
  };
  /* verilator lint_on UNUSEDPARAM */

endpackage
