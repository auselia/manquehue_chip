// Copyright 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Cells to be used for Xilinx FPGA mappings

module tc_clk_and2 (
  input  logic clk0_i,
  input  logic clk1_i,
  output logic clk_o
);

  assign clk_o = clk0_i & clk1_i;

endmodule

module tc_clk_buffer (
  input  logic clk_i,
  output logic clk_o
);

  assign clk_o = clk_i;

endmodule

// Disable clock gating on FPGA as it behaves differently than expected
module tc_clk_gating #(
  /// This paramaeter is a hint for tool/technology specific mappings of this
  /// tech_cell. It indicates wether this particular clk gate instance is
  /// required for functional correctness or just instantiated for power
  /// savings. If IS_FUNCTIONAL == 0, technology specific mappings might
  /// replace this cell with a feedthrough connection without any gating.
  parameter bit IS_FUNCTIONAL = 1'b1
)(
   input  logic clk_i,
   input  logic en_i,
   input  logic test_en_i,
   output logic clk_o
);

  assign clk_o = clk_i;

endmodule

module tc_clk_inverter (
  input  logic clk_i,
  output logic clk_o
);

  assign clk_o = ~clk_i;

endmodule

module tc_clk_mux2 (
  input  logic clk0_i,
  input  logic clk1_i,
  input  logic clk_sel_i,
  output logic clk_o
);

  // BUFGCTRL with IGNORE0/IGNORE1 = 1: the select acts at once. A BUFGMUX waits for a falling edge of the clock it
  // leaves, and croc switches the shared SPI SCLK (adc_rdr i_sclk_own) away from the ADC SCLK, which idles high:
  // that edge never comes and the pad stays high (radio SCK stuck at 1 on the ZedBoard, 9 Nov 2026). The other
  // users (JTAG test-mode mux, reset bypass) have static selects. FPGA only: the chip uses a plain mux cell.
  BUFGCTRL i_BUFGMUX (
    .O       ( clk_o      ),
    .CE0     ( 1'b1       ),
    .CE1     ( 1'b1       ),
    .I0      ( clk0_i     ),
    .I1      ( clk1_i     ),
    .IGNORE0 ( 1'b1       ),
    .IGNORE1 ( 1'b1       ),
    .S0      ( ~clk_sel_i ),
    .S1      ( clk_sel_i  )
  );

endmodule

module tc_clk_xor2 (
  input  logic clk0_i,
  input  logic clk1_i,
  output logic clk_o
);

  assign clk_o = clk0_i ^ clk1_i;

endmodule

module tc_clk_or2 (
  input logic clk0_i,
  input logic clk1_i,
  output logic clk_o
);

  assign clk_o = clk0_i | clk1_i;

endmodule


