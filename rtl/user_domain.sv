// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

module user_domain import user_pkg::*; import croc_pkg::*; #(
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
  output logic [2:0] qspi_csn_o
);

  // [0] radio master, [1] ADC reader (SPI block), [2] FFT (later), [3] reserved
  logic [1:0] spi_irq;
  assign interrupts_o = NumExternalIrqs'(spi_irq);


  //////////////////////
  // User Manager MUX //
  /////////////////////

  mgr_obi_req_t [NumUserMgr-1:0] user_mgr_req;
  mgr_obi_rsp_t [NumUserMgr-1:0] user_mgr_rsp;

  // FFT manager, idle until the FFT block is in
  assign user_mgr_req[UserMgrFft] = '0;

  obi_mux #(
    .SbrPortObiCfg      ( MgrObiCfg        ),
    .MgrPortObiCfg      ( MgrObiCfg        ),
    .sbr_port_obi_req_t ( mgr_obi_req_t    ),
    .sbr_port_a_chan_t  ( mgr_obi_a_chan_t ),
    .sbr_port_obi_rsp_t ( mgr_obi_rsp_t    ),
    .sbr_port_r_chan_t  ( mgr_obi_r_chan_t ),
    .NumSbrPorts        ( NumUserMgr       ),
    .NumMaxTrans        ( 2                ),
    .UseIdForRouting    ( 1'b0             )
  ) i_user_mgr_mux (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .sbr_ports_req_i ( user_mgr_req       ),
    .sbr_ports_rsp_o ( user_mgr_rsp       ),
    .mgr_port_req_o  ( user_mgr_obi_req_o ),
    .mgr_port_rsp_i  ( user_mgr_obi_rsp_i )
  );


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
  sbr_obi_req_t user_spi_obi_req;
  sbr_obi_rsp_t user_spi_obi_rsp;

  // Fanout into more readable signals
  assign user_error_obi_req               = all_user_sbr_obi_req[UserError];
  assign all_user_sbr_obi_rsp[UserError]  = user_error_obi_rsp;
  assign user_design_obi_req              = all_user_sbr_obi_req[UserDesign];
  assign all_user_sbr_obi_rsp[UserDesign] = user_design_obi_rsp;
  assign user_qspi_obi_req              = all_user_sbr_obi_req[UserQSpi];
  assign all_user_sbr_obi_rsp[UserQSpi] = user_qspi_obi_rsp;
  assign user_spi_obi_req               = all_user_sbr_obi_req[UserSpi];
  assign all_user_sbr_obi_rsp[UserSpi]  = user_spi_obi_rsp;


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

  // SPI block. The pads are not yet ports of croc_soc (integration step, AUS-18): the inputs are tied to
  // their inactive levels and the outputs are left open.
  obi_spi_pkg::spi_pads_out_t spi_pads_out;
  obi_spi_pkg::spi_pads_in_t  spi_pads_in;
  assign spi_pads_in = obi_spi_pkg::PadsInIdle;

  obi_spi #(
    .SbrObiCfg ( SbrObiCfg     ),
    .sbr_req_t ( sbr_obi_req_t ),
    .sbr_rsp_t ( sbr_obi_rsp_t ),
    .mgr_req_t ( mgr_obi_req_t ),
    .mgr_rsp_t ( mgr_obi_rsp_t )
  ) i_obi_spi (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .obi_sbr_req_i ( user_spi_obi_req         ),
    .obi_sbr_rsp_o ( user_spi_obi_rsp         ),
    .obi_mgr_req_o ( user_mgr_req[UserMgrSpi] ),
    .obi_mgr_rsp_i ( user_mgr_rsp[UserMgrSpi] ),
    .irq_o         ( spi_irq                  ),
    .pads_o        ( spi_pads_out             ),
    .pads_i        ( spi_pads_in              )
  );

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