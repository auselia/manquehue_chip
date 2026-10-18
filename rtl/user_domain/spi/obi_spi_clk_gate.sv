// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Clock gate of the forwarded ADC SCLK: clk_o = clk_i AND en_i, enable latched while clk_i is low.
// For GF180 this is the positive-edge gate cell gf180mcu_fd_sc_mcu7t5v0__icgtp, the cell of the flow experiment
// (sim/experiments/fwd_clock). tc_clk_gating is not used: on GF180 it maps to the negative-edge cell icgtn,
// whose output idles high and follows the opposite clock phase, so SCLK would not have the timing of the experiment.

module obi_spi_clk_gate (
  input  logic clk_i,
  input  logic en_i,
  input  logic test_en_i,
  output logic clk_o
);

`ifdef TARGET_GF180
  (* keep *)(* dont_touch = "true" *)
  gf180mcu_fd_sc_mcu7t5v0__icgtp_4 i_icg (
    .CLK ( clk_i     ),
    .E   ( en_i      ),
    .TE  ( test_en_i ),
    .Q   ( clk_o     )
  );
`else
  logic en_latched;
  /* verilator lint_off COMBDLY */
  always_latch begin
    if (clk_i == 1'b0) en_latched <= en_i | test_en_i;
  end
  /* verilator lint_on COMBDLY */
  assign clk_o = clk_i & en_latched;
`endif

endmodule
