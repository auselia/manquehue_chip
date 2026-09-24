// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

module user_domain import user_pkg::*; import croc_pkg::*; import spi_host_reg_pkg::*; #(
  parameter int unsigned GpioCount = 16,
  parameter int unsigned NumExternalIrqs = 4
) (
  input  logic      clk_i,
  input  logic      ref_clk_i,
  input  logic      rst_ni,
  input  logic      testmode_i,

  input  sbr_obi_req_t user_sbr_obi_req_i, // User Sbr (rsp_o), Croc Mgr (req_i)
  output sbr_obi_rsp_t user_sbr_obi_rsp_o,

  output mgr_obi_req_t user_mgr_obi_req_o, // User Mgr (req_o), Croc Sbr (rsp_i)
  input  mgr_obi_rsp_t user_mgr_obi_rsp_i,

  input  logic [      GpioCount-1:0] gpio_in_sync_i, // synchronized GPIO inputs
  output logic [NumExternalIrqs-1:0] interrupts_o,    // interrupts to core

  output logic       qspi_clk_o,
  output logic [3:0] qspi_sd_o,
  input  logic [3:0] qspi_sd_i,
  output logic [3:0] qspi_sd_en_o,
  output logic [2:0] qspi_csn_o,

  // obi_spi_host (ADC + LoRa SPI master, shared bus, 2 chip selects). Raw
  // peripheral-side signals -- croc_soc.sv is where these actually get muxed
  // onto shared pads with pinmux_sel_o below, since it's the only place both
  // this domain's and croc_domain's signals are visible together.
  output logic             spi_sck_o,
  output logic [NumCS-1:0] spi_csb_o,
  output logic [3:0]       spi_sd_o,
  output logic [3:0]       spi_sd_en_o,
  input  logic [3:0]       spi_sd_i,

  // Pad-sharing pinmux select, memory-mapped at UserPinmux (see user_pkg.sv).
  // bit0 UART_SEL:   uart_rx_i/uart_tx_o    -> spi MISO (sd[1]) / SCK
  // bit1 GPIO01_SEL: gpio0_io/gpio1_io      -> spi CS1 / MOSI (sd[0])
  // bit2 STATUS_SEL: status_o (core_busy_o) -> spi CS0
  // Resets to 0 (everything in its stock role) so the chip always comes up
  // with a working console/GPIO/status pin; firmware opts into the SPI
  // wiring explicitly once boot is confirmed sane.
  output logic [2:0] pinmux_sel_o
);

  // interrupts_o[0]: spi_host spi_event (CSID/watermark/idle/... per EVENT_ENABLE)
  // interrupts_o[1]: spi_host error (per ERROR_ENABLE)
  // interrupts_o[NumExternalIrqs-1:2]: unused for now (e.g. a future AFE wake
  // trigger would go here as its own dedicated fast IRQ, see project notes)
  logic spi_host_intr_event, spi_host_intr_error;
  assign interrupts_o = {{(NumExternalIrqs-2){1'b0}}, spi_host_intr_error, spi_host_intr_event};


  //////////////////////
  // User Manager MUX //
  /////////////////////

  // No manager so we don't need a obi_mux module and just terminate the request properly
  assign user_mgr_obi_req_o = '0;


  ////////////////////////////
  // User Subordinate DEMUX //
  ////////////////////////////

  // ----------------------------------------------------------------------------------------------
  // User Subordinate Buses
  // ----------------------------------------------------------------------------------------------

  // collection of signals from the demultiplexer
  sbr_obi_req_t [NumDemuxSbr-1:0] all_user_sbr_obi_req;
  sbr_obi_rsp_t [NumDemuxSbr-1:0] all_user_sbr_obi_rsp;

  // Error Subordinate Bus
  sbr_obi_req_t user_error_obi_req;
  sbr_obi_rsp_t user_error_obi_rsp;

  // OBI bus to your design
  sbr_obi_req_t user_design_obi_req;
  sbr_obi_rsp_t user_design_obi_rsp;
  sbr_obi_req_t user_qspi_obi_req;
  sbr_obi_rsp_t user_qspi_obi_rsp;
  sbr_obi_req_t user_spi_host_obi_req;
  sbr_obi_rsp_t user_spi_host_obi_rsp;
  sbr_obi_req_t user_pinmux_obi_req;
  sbr_obi_rsp_t user_pinmux_obi_rsp;

  // Fanout into more readable signals
  assign user_error_obi_req               = all_user_sbr_obi_req[UserError];
  assign all_user_sbr_obi_rsp[UserError]  = user_error_obi_rsp;
  assign user_design_obi_req              = all_user_sbr_obi_req[UserDesign];
  assign all_user_sbr_obi_rsp[UserDesign] = user_design_obi_rsp;
  assign user_qspi_obi_req             = all_user_sbr_obi_req[UserQSpi];
  assign all_user_sbr_obi_rsp[UserQSpi] = user_qspi_obi_rsp;
  assign user_spi_host_obi_req             = all_user_sbr_obi_req[UserSpiHost];
  assign all_user_sbr_obi_rsp[UserSpiHost] = user_spi_host_obi_rsp;
  assign user_pinmux_obi_req             = all_user_sbr_obi_req[UserPinmux];
  assign all_user_sbr_obi_rsp[UserPinmux] = user_pinmux_obi_rsp;


  //-----------------------------------------------------------------------------------------------
  // Demultiplex to User Subordinates according to address map
  //-----------------------------------------------------------------------------------------------

  logic [cf_math_pkg::idx_width(NumDemuxSbr)-1:0] user_idx;

  addr_decode #(
    .NoIndices ( NumDemuxSbr                    ),
    .NoRules   ( $size(UserAddrMap)             ),
    .addr_t    ( logic[SbrObiCfg.DataWidth-1:0] ),
    .rule_t    ( addr_map_rule_t                ),
    .Napot     ( 1'b0                           )
  ) i_addr_decode_periphs (
    .addr_i           ( user_sbr_obi_req_i.a.addr ),
    .addr_map_i       ( UserAddrMap               ),
    .idx_o            ( user_idx                  ),
    .dec_valid_o      (),
    .dec_error_o      (),
    .en_default_idx_i ( 1'b1                      ),
    .default_idx_i    ( 2'(UserError)             )
  );

  obi_demux #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMgrPorts ( NumDemuxSbr   ),
    .NumMaxTrans ( 2             )
  ) i_obi_demux (
    .clk_i,
    .rst_ni,

    .sbr_port_select_i ( user_idx             ),
    .sbr_port_req_i    ( user_sbr_obi_req_i   ),
    .sbr_port_rsp_o    ( user_sbr_obi_rsp_o   ),

    .mgr_ports_req_o   ( all_user_sbr_obi_req ),
    .mgr_ports_rsp_i   ( all_user_sbr_obi_rsp )
  );


//-------------------------------------------------------------------------------------------------
// User Subordinates
//-------------------------------------------------------------------------------------------------

  obi_qspi #(
    .ObiCfg     ( SbrObiCfg                  ),
    .obi_req_t  ( sbr_obi_req_t              ),
    .obi_rsp_t  ( sbr_obi_rsp_t              ),
    .NumCs      ( 3                          ),
    .WindowBase ( user_pkg::UserQSpiAddrBase ) // window-relative offset = addr - base
  ) i_obi_qspi (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .obi_req_i    ( user_qspi_obi_req ),
    .obi_rsp_o    ( user_qspi_obi_rsp ),
    .spi_clk_o    ( qspi_clk_o    ),
    .spi_sd_o     ( qspi_sd_o     ),
    .spi_sd_i     ( qspi_sd_i     ),
    .spi_sd_en_o  ( qspi_sd_en_o  ),
    .spi_csn_o    ( qspi_csn_o    )
  );

  // obi_spi_host: ADC + LoRa SPI master (OpenTitan spi_host over an OBI<->TL-UL
  // bridge, see rtl/obi_spi/README.md). NumCS=2 -- one CS per device, sharing
  // spi_sck_o/spi_sd_*, each with its own CONFIGOPTS clock-divider/mode
  // selected per-transaction via CSID.
  obi_spi_host #(
    .ObiCfg    ( SbrObiCfg     ),
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_obi_spi_host (
    .clk_i,
    .rst_ni,
    .obi_req_i ( user_spi_host_obi_req ),
    .obi_rsp_o ( user_spi_host_obi_rsp ),

    .spi_sck_o,
    .spi_csb_o,
    .spi_sd_o,
    .spi_sd_en_o,
    .spi_sd_i,

    .intr_error_o      ( spi_host_intr_error ),
    .intr_spi_event_o  ( spi_host_intr_event )
  );

  // Pinmux register: a single word, hand-written rather than a full reg_top
  // (same ID-tracking shell as obi_err_sbr.sv, just with real read/write
  // behaviour instead of always erroring). Croc's SbrObiCfg has
  // UseRReady=1'b0, so -- matching obi_err_sbr's own pattern for that config
  // -- a depth-1 ID FIFO is sufficient; nothing here needs more than one
  // outstanding transaction.
  logic [2:0] pinmux_sel_q;
  logic [SbrObiCfg.IdWidth-1:0] pinmux_rid;
  logic pinmux_fifo_full, pinmux_fifo_empty, pinmux_fifo_pop;

  always_comb begin
    user_pinmux_obi_rsp         = '0;
    user_pinmux_obi_rsp.r.rdata = {29'b0, pinmux_sel_q};
    user_pinmux_obi_rsp.r.rid   = pinmux_rid;
    user_pinmux_obi_rsp.r.err   = 1'b0;
    user_pinmux_obi_rsp.gnt     = ~pinmux_fifo_full;
    user_pinmux_obi_rsp.rvalid  = ~pinmux_fifo_empty;
  end

  assign pinmux_fifo_pop = user_pinmux_obi_rsp.rvalid; // SbrObiCfg.UseRReady == 1'b0

  fifo_v3 #(
    .DEPTH        ( 1                  ),
    .FALL_THROUGH ( 1'b0               ),
    .DATA_WIDTH   ( SbrObiCfg.IdWidth  )
  ) i_pinmux_id_fifo (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .flush_i ( '0 ),
    .full_o  ( pinmux_fifo_full  ),
    .empty_o ( pinmux_fifo_empty ),
    .usage_o (),
    .data_i  ( user_pinmux_obi_req.a.aid ),
    .push_i  ( user_pinmux_obi_req.req && user_pinmux_obi_rsp.gnt ),
    .data_o  ( pinmux_rid ),
    .pop_i   ( pinmux_fifo_pop )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pinmux_sel_q <= 3'b000;
    end else if (user_pinmux_obi_req.req && user_pinmux_obi_rsp.gnt && user_pinmux_obi_req.a.we) begin
      pinmux_sel_q <= user_pinmux_obi_req.a.wdata[2:0];
    end
  end

  assign pinmux_sel_o = pinmux_sel_q;

  // UserDesign placeholder.
  // Nothing was driving `user_design_obi_rsp`, so ANY access decoded to UserDesign
  // returned X on rdata/gnt/rvalid. Terminate it with an error subordinate so a stray
  // access gets a clean OBI error instead of X. Replace this block with your real design
  // module when you add one (wire it to user_design_obi_req / user_design_obi_rsp).
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_user_design_placeholder (
    .clk_i,
    .rst_ni,
    .testmode_i ( testmode_i          ),
    .obi_req_i  ( user_design_obi_req ),
    .obi_rsp_o  ( user_design_obi_rsp )
  );

  // Error Subordinate
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_user_err (
    .clk_i,
    .rst_ni,
    .testmode_i ( testmode_i         ),
    .obi_req_i  ( user_error_obi_req ),
    .obi_rsp_o  ( user_error_obi_rsp )
  );

endmodule
