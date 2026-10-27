// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

module croc_soc import croc_pkg::*; #(
  parameter int unsigned GpioCount = 2
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ref_clk_i,
  input  logic testmode_i,
  output logic status_o,

  input  logic jtag_tck_i,
  input  logic jtag_tdi_i,
  output logic jtag_tdo_o,
  input  logic jtag_tms_i,
  input  logic jtag_trst_ni,

  input  logic uart_rx_i,
  output logic uart_tx_o,

  output logic       qspi_clk_o,
  output logic [3:0] qspi_sd_o,
  input  logic [3:0] qspi_sd_i,
  output logic [3:0] qspi_sd_en_o,
  output logic [2:0] qspi_csn_o,

  // SPI block (docs/spi_adc_spec.md section 3): ADS7057 ADC and SX1276 radio on one shared bus
  output logic spi_sck_o,      // ADC: forwarded system clock, idles high. Radio: its SCLK while it owns the bus
  output logic spi_sd_o,       // radio MOSI
  input  logic spi_sd_i,       // ADC SDO and radio MISO
  output logic spi_cs0_o,      // ADC chip select, active low
  output logic spi_cs1_o,      // radio chip select, active low
  input  logic afe_irq_i,      // window comparator of the AFE board (WAKE_N), active low
  input  logic rf_dio0_i,      // radio interrupt (TxDone, RxDone)
  output logic rf_rstn_o,      // radio reset, active low

  input  logic [GpioCount-1:0] gpio_i,       // Input from GPIO pins
  output logic [GpioCount-1:0] gpio_o,       // Output to GPIO pins
  output logic [GpioCount-1:0] gpio_out_en_o // Output enable signal; 0 -> input, 1 -> output
);

  logic synced_rst_n;

  rstgen i_rstgen (
    .clk_i,
    .rst_ni,
    .test_mode_i ( testmode_i ),
    .rst_no      ( synced_rst_n ),
    .init_no     ()
  );

// Connection between Croc_domain and User_domain: User Sbr, Croc Mgr
sbr_obi_req_t user_sbr_obi_req;
sbr_obi_rsp_t user_sbr_obi_rsp;

// Connection between Croc_domain and User_domain: Croc Sbr, User Mgr
mgr_obi_req_t user_mgr_obi_req;
mgr_obi_rsp_t user_mgr_obi_rsp;

localparam int unsigned NumExternalIrqs = 4;
logic [NumExternalIrqs-1:0] interrupts;
logic [      GpioCount-1:0] gpio_in_sync;

croc_domain #(
  .GpioCount       ( GpioCount       ),
  .NumExternalIrqs ( NumExternalIrqs )
) i_croc (
  .clk_i,
  .rst_ni ( synced_rst_n ),
  .ref_clk_i,
  .testmode_i,

  .jtag_tck_i,
  .jtag_tdi_i,
  .jtag_tdo_o,
  .jtag_tms_i,
  .jtag_trst_ni,

  .uart_rx_i,
  .uart_tx_o,

  .gpio_i,
  .gpio_o,
  .gpio_out_en_o,

  .gpio_in_sync_o ( gpio_in_sync ),

  .user_sbr_obi_req_o  ( user_sbr_obi_req ),
  .user_sbr_obi_rsp_i  ( user_sbr_obi_rsp ),

  .user_mgr_obi_req_i  ( user_mgr_obi_req ),
  .user_mgr_obi_rsp_o  ( user_mgr_obi_rsp ),

  .interrupts_i ( interrupts ),
  .core_busy_o  ( status_o   )
);

obi_spi_pkg::spi_pads_out_t spi_pads_out;
obi_spi_pkg::spi_pads_in_t  spi_pads_in;

assign spi_sck_o   = spi_pads_out.sck;
assign spi_sd_o    = spi_pads_out.sd_o;
assign spi_cs0_o   = spi_pads_out.cs0_n;
assign spi_cs1_o   = spi_pads_out.cs1_n;
assign rf_rstn_o   = spi_pads_out.rf_rstn;
assign spi_pads_in = '{
  sd_i:      spi_sd_i,
  afe_irq_n: afe_irq_i,
  rf_dio0:   rf_dio0_i
};

user_domain #(
  .GpioCount       ( GpioCount       ),
  .NumExternalIrqs ( NumExternalIrqs )
) i_user (
  .clk_i,
  .rst_ni ( synced_rst_n ),
  .ref_clk_i,
  .testmode_i,

  .user_sbr_obi_req_i ( user_sbr_obi_req ),
  .user_sbr_obi_rsp_o ( user_sbr_obi_rsp ),

  .user_mgr_obi_req_o ( user_mgr_obi_req ),
  .user_mgr_obi_rsp_i ( user_mgr_obi_rsp ),

  .gpio_in_sync_i ( gpio_in_sync ),
  .interrupts_o   ( interrupts   ),

  .qspi_clk_o  ( qspi_clk_o  ),
  .qspi_sd_o   ( qspi_sd_o   ),
  .qspi_sd_i   ( qspi_sd_i   ),
  .qspi_sd_en_o ( qspi_sd_en_o ),
  .qspi_csn_o   ( qspi_csn_o   ),

  .spi_pads_o   ( spi_pads_out ),
  .spi_pads_i   ( spi_pads_in  )
);

endmodule
