// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

module croc_soc import croc_pkg::*; import spi_host_reg_pkg::*; #(
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

  input  logic [GpioCount-1:0] gpio_i,       // Input from GPIO pins
  output logic [GpioCount-1:0] gpio_o,       // Output to GPIO pins
  output logic [GpioCount-1:0] gpio_out_en_o // Output enable signal; 0 -> input, 1 -> output
);

  // Pin budget: the ADC/LoRa SPI master (obi_spi_host, in user_domain) does
  // NOT get its own package pins. Its 5 signals (SCK, CS0, CS1, MOSI, MISO)
  // share physical pads with uart_rx_i/uart_tx_o, status_o and gpio0/gpio1,
  // switched by the pinmux register in user_domain.sv (UserPinmux, resets to
  // "everything in its stock role"). This keeps croc_soc.sv's package pin
  // count unchanged from the pre-obi_spi_host pinout -- see rtl/obi_spi/README.md
  // and the project's pin-budget notes for why this specific pad assignment
  // (only standard single-lane SPI is used, so sd[3:2] are unused/tied off):
  //
  //   uart_rx_i  (in)     <-> spi MISO  (sd[1])   -- native direction match
  //   uart_tx_o  (out)    <-> spi SCK               -- native direction match
  //   status_o   (out)    <-> spi CS0   (csb[0])    -- native direction match
  //   gpio0_io   (bidir)  <-> spi CS1   (csb[1])
  //   gpio1_io   (bidir)  <-> spi MOSI  (sd[0])
  //
  // jtag_trst_ni is untouched -- no pin was reclaimed from JTAG for this.

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

// croc_domain's own pre-mux drivers for the shared pads
logic                  croc_uart_tx_o;
logic                  croc_status_o;
logic [GpioCount-1:0]  croc_gpio_o;
logic [GpioCount-1:0]  croc_gpio_out_en_o;

// user_domain's raw obi_spi_host signals, pre-mux
logic             user_spi_sck_o;
logic [NumCS-1:0] user_spi_csb_o;
logic [3:0]       user_spi_sd_o;
logic [3:0]       user_spi_sd_en_o;
logic [3:0]       user_spi_sd_i;
logic [2:0]       pinmux_sel;

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
  .uart_tx_o ( croc_uart_tx_o ),

  .gpio_i,
  .gpio_o        ( croc_gpio_o        ),
  .gpio_out_en_o ( croc_gpio_out_en_o ),

  .gpio_in_sync_o ( gpio_in_sync ),

  .user_sbr_obi_req_o  ( user_sbr_obi_req ),
  .user_sbr_obi_rsp_i  ( user_sbr_obi_rsp ),

  .user_mgr_obi_req_i  ( user_mgr_obi_req ),
  .user_mgr_obi_rsp_o  ( user_mgr_obi_rsp ),

  .interrupts_i ( interrupts ),
  .core_busy_o  ( croc_status_o )
);

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

  .spi_sck_o    ( user_spi_sck_o    ),
  .spi_csb_o    ( user_spi_csb_o    ),
  .spi_sd_o     ( user_spi_sd_o     ),
  .spi_sd_en_o  ( user_spi_sd_en_o  ),
  .spi_sd_i     ( user_spi_sd_i     ),

  .pinmux_sel_o ( pinmux_sel )
);

//-------------------------------------------------------------------------------------------------
// Pad-sharing pinmux -- see NOTE above and rtl/obi_spi/README.md
//-------------------------------------------------------------------------------------------------

  // uart_rx_i (in): fans out to both consumers unconditionally, no mux needed
  // -- the UART peripheral harmlessly ignores it while nobody reads its rx
  // register, and obi_spi_host only samples sd[1] when it's actually driving
  // a transaction on CS0/CS1.
  assign user_spi_sd_i = {2'b00, uart_rx_i, 1'b0}; // sd[3:2] unused (no quad/dual), sd[1]=MISO, sd[0]=unused (MOSI pad's own input is never sampled)

  assign uart_tx_o = pinmux_sel[0] ? user_spi_sck_o : croc_uart_tx_o;
  assign status_o  = pinmux_sel[2] ? user_spi_csb_o[0] : croc_status_o;

  // Default to full passthrough (any GpioCount > 2 stays untouched on bits
  // [GpioCount-1:2]), override just gpio0/gpio1 when SPI mode is selected.
  always_comb begin
    gpio_o        = croc_gpio_o;
    gpio_out_en_o = croc_gpio_out_en_o;
    if (pinmux_sel[1]) begin
      gpio_o[0]        = user_spi_csb_o[1]; // CS1
      gpio_out_en_o[0] = 1'b1;
      gpio_o[1]        = user_spi_sd_o[0];    // MOSI
      gpio_out_en_o[1] = user_spi_sd_en_o[0];
    end
  end

endmodule
