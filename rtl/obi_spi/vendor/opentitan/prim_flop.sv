// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// NOTE: renamed from prim_generic_flop.sv at hw/ip/prim_generic/rtl/ --
// this OpenTitan tag predates the prim_generic/prim_xilinx technology-selection
// wrapper for this module, so the plain prim_* name spi_host.sv instantiates
// only exists as prim_generic_*. We vendor one concrete implementation and
// rename it, rather than pull in a technology-selection layer we do not need.
`include "prim_assert.sv"

module prim_flop #(
  parameter int               Width      = 1,
  parameter logic [Width-1:0] ResetValue = 0
) (
  input                    clk_i,
  input                    rst_ni,
  input        [Width-1:0] d_i,
  output logic [Width-1:0] q_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q_o <= ResetValue;
    end else begin
      q_o <= d_i;
    end
  end

endmodule
