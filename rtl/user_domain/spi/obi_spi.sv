// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// OBI SPI block: radio SPI master (SX1276) at 0x000..0x0FF and ADS7057 reader at 0x100..0x1FF of a 4 KB window,
// spec docs/spi_adc_spec.md.
// Skeleton: the bus front end, the manager port, the interrupts and the pads are in place. The two sub-blocks
// (rf_spi, adc_rdr) are not yet. Until then every register reads 0, writes have no effect, the pads stay at
// obi_spi_pkg::PadsOutIdle and the manager port makes no request.

module obi_spi import obi_spi_pkg::*; #(
  /// OBI configuration of the subordinate port (SbrObiCfg)
  parameter obi_pkg::obi_cfg_t SbrObiCfg = obi_pkg::ObiDefaultConfig,
  parameter type               sbr_req_t = logic,
  parameter type               sbr_rsp_t = logic,
  /// OBI configuration of the manager port (MgrObiCfg), the ADC reader writes the samples to SRAM through it.
  /// Not used before the ADC reader is in (the waiver goes with it).
  /* verilator lint_off UNUSEDPARAM */
  parameter obi_pkg::obi_cfg_t MgrObiCfg = obi_pkg::ObiDefaultConfig,
  /* verilator lint_on UNUSEDPARAM */
  parameter type               mgr_req_t = logic,
  parameter type               mgr_rsp_t = logic
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic          testmode_i,

  input  sbr_req_t      obi_sbr_req_i,
  output sbr_rsp_t      obi_sbr_rsp_o,

  output mgr_req_t      obi_mgr_req_o,
  input  mgr_rsp_t      obi_mgr_rsp_i,

  /// [0] radio master, [1] ADC reader. Level, cleared at the source.
  output logic [1:0]    irq_o,

  output spi_pads_out_t pads_o,
  input  spi_pads_in_t  pads_i
);

  logic [AddrBits-1:0]              addr;
  logic                             wr_valid, rd_valid;
  logic [SbrObiCfg.DataWidth-1:0]   wdata, rdata;
  logic [SbrObiCfg.DataWidth/8-1:0] be;

  obi_spi_regs #(
    .ObiCfg    ( SbrObiCfg ),
    .obi_req_t ( sbr_req_t ),
    .obi_rsp_t ( sbr_rsp_t )
  ) i_regs (
    .clk_i,
    .rst_ni,
    .obi_req_i  ( obi_sbr_req_i ),
    .obi_rsp_o  ( obi_sbr_rsp_o ),
    .addr_o     ( addr          ),
    .wr_valid_o ( wr_valid      ),
    .wdata_o    ( wdata         ),
    .be_o       ( be            ),
    .rd_valid_o ( rd_valid      ),
    .rdata_i    ( rdata         )
  );

  // Sub-block select: word address bits [9:6] are byte address bits [11:8] (radio: 0x000..0x0FF, ADC: 0x100..0x1FF)
  logic sel_rf, sel_adc;
  assign sel_rf  = addr[AddrBits-1:6] == RfBase[WindowBits-1:8];
  assign sel_adc = addr[AddrBits-1:6] == AdcBase[WindowBits-1:8];

  // Placeholders for rf_spi and adc_rdr
  logic [SbrObiCfg.DataWidth-1:0] rf_rdata, adc_rdata;
  assign rf_rdata  = '0;
  assign adc_rdata = '0;
  assign rdata     = sel_adc ? adc_rdata : (sel_rf ? rf_rdata : '0);

  assign obi_mgr_req_o = '0;
  assign irq_o         = '0;
  assign pads_o        = PadsOutIdle;

  // Not used until the sub-blocks are in. Remove with the first sub-block.
  logic unused;
  assign unused = ^{testmode_i, wr_valid, rd_valid, wdata, be, addr[5:0], obi_mgr_rsp_i, pads_i};
endmodule
