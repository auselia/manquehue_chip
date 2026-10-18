// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Lint top of obi_spi: the block with the OBI types of the SoC, as user_domain instantiates it.
// Used by scripts/sim/run_obi_spi_tb.sh (verilator --lint-only -Wall).

module obi_spi_lint_top import croc_pkg::*; import obi_spi_pkg::*; (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic          testmode_i,
  input  sbr_obi_req_t  obi_sbr_req_i,
  output sbr_obi_rsp_t  obi_sbr_rsp_o,
  output mgr_obi_req_t  obi_mgr_req_o,
  input  mgr_obi_rsp_t  obi_mgr_rsp_i,
  output logic [1:0]    irq_o,
  output spi_pads_out_t pads_o,
  input  spi_pads_in_t  pads_i
);

  obi_spi #(
    .SbrObiCfg ( SbrObiCfg     ),
    .sbr_req_t ( sbr_obi_req_t ),
    .sbr_rsp_t ( sbr_obi_rsp_t ),
    .mgr_req_t ( mgr_obi_req_t ),
    .mgr_rsp_t ( mgr_obi_rsp_t )
  ) i_obi_spi (.*);

endmodule
