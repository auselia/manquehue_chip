// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// OBI SPI block: radio SPI master (SX1276) at 0x000..0x0FF and ADS7057 reader at 0x100..0x1FF of a 4 KB window,
// spec docs/spi_adc_spec.md.
// Both sub-blocks are in: the radio master (rf_spi) on 0x000..0x0FF and the ADC reader (adc_rdr) on 0x100..0x1FF.

module obi_spi import obi_spi_pkg::*; #(
  /// OBI configuration of the subordinate port (SbrObiCfg)
  parameter obi_pkg::obi_cfg_t SbrObiCfg = obi_pkg::ObiDefaultConfig,
  parameter type               sbr_req_t = logic,
  parameter type               sbr_rsp_t = logic,
  /// OBI types of the manager port (mgr_obi_req_t, mgr_obi_rsp_t), the ADC reader writes the samples to SRAM through it
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

  logic [SbrObiCfg.DataWidth-1:0] rf_rdata, adc_rdata;
  logic                           adc_irq, rf_irq;
  assign rdata = sel_adc ? adc_rdata : (sel_rf ? rf_rdata : '0);

  // ---------------------------------------------------------------- ADC reader
  adc_rdr #(
    .mgr_req_t ( mgr_req_t ),
    .mgr_rsp_t ( mgr_rsp_t )
  ) i_adc_rdr (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .reg_addr_i  ( addr[5:0]           ),
    .reg_wr_i    ( wr_valid & sel_adc  ),
    .reg_wdata_i ( wdata               ),
    .reg_be_i    ( be                  ),
    .reg_rdata_o ( adc_rdata           ),
    .mgr_req_o   ( obi_mgr_req_o       ),
    .mgr_rsp_i   ( obi_mgr_rsp_i       ),
    .irq_o       ( adc_irq             ),
    .sclk_o      ( pads_o.adc_sclk     ),
    .csn_o       ( pads_o.adc_csn      ),
    .sdo_i       ( pads_i.adc_sdo      ),
    .wake_n_i    ( pads_i.adc_wake_n   ),
    .big_n_i     ( pads_i.adc_big_n    ),
    .wake_clr_o  ( pads_o.adc_wake_clr ),
    .cap_en_o    ( pads_o.adc_cap_en   )
  );

  // ---------------------------------------------------------------- radio master
  rf_spi i_rf_spi (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .reg_addr_i  ( addr[5:0]          ),
    .reg_wr_i    ( wr_valid & sel_rf  ),
    .reg_rd_i    ( rd_valid & sel_rf  ),
    .reg_wdata_i ( wdata              ),
    .reg_be_i    ( be                 ),
    .reg_rdata_o ( rf_rdata           ),
    .irq_o       ( rf_irq             ),
    .sclk_o      ( pads_o.rf_sclk     ),
    .mosi_o      ( pads_o.rf_mosi     ),
    .miso_i      ( pads_i.rf_miso     ),
    .csn_o       ( pads_o.rf_csn      ),
    .dio0_i      ( pads_i.rf_dio0     ),
    .rstn_o      ( pads_o.rf_rstn     )
  );

  assign irq_o = {adc_irq, rf_irq};
endmodule
