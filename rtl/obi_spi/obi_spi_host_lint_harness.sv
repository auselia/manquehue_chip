// Copyright and related rights waived via CC0.
//
// Lint-only harness: binds obi_spi_host to Croc's real sbr_obi_req_t/rsp_t
// (from croc_pkg) instead of the generic `logic` defaults, so a standalone
// lint pass exercises the module the way user_domain.sv will actually
// instantiate it. Not part of the design -- verification scaffolding only.
module obi_spi_host_lint_harness
  import croc_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,

  input  sbr_obi_req_t obi_req_i,
  output sbr_obi_rsp_t obi_rsp_o,

  output logic              spi_sck_o,
  output logic [spi_host_reg_pkg::NumCS-1:0] spi_csb_o,
  output logic [3:0]        spi_sd_o,
  output logic [3:0]        spi_sd_en_o,
  input  logic [3:0]        spi_sd_i,

  output logic intr_error_o,
  output logic intr_spi_event_o
);

  obi_spi_host #(
    .ObiCfg    ( croc_pkg::SbrObiCfg  ),
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_dut (
    .clk_i, .rst_ni,
    .obi_req_i, .obi_rsp_o,
    .spi_sck_o, .spi_csb_o, .spi_sd_o, .spi_sd_en_o, .spi_sd_i,
    .intr_error_o, .intr_spi_event_o
  );

endmodule
