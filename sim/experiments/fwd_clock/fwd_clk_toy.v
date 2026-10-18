// Forwarded-clock experiment (AUS-16, spec section 6): the frame engine of the ADC reader with SCLK = the system clock
// through a clock-gate cell and an inverter, nothing else. Used to see what the flow does with a clock that leaves
// through a port (CTS, duty cycle, timing of CS and SDO) and, in simulation, that the frame is what the ADS7057
// datasheet wants.
//
// Frame (state c = 0..19, one state per system clock, period 20 clocks):
//   CS low in states 0..18, SCLK falls at the clock edges that start states 1..18 (18 falling edges),
//   enable of the gate high in states 0..17, CS high in state 19, so CS rises one clock after the 18th falling edge and
//   the next CS fall is two clocks after it (tACQ = 2 clocks = 110 ns at 55 ns).
// Capture: SDO is sampled at the falling SCLK edges, the first is the leading zero, then D13..D0.
module fwd_clk_toy #(
  parameter SAMPLE_DLY = 0                 // 1: one more register stage in the SDO path
) (
  input  wire        clk_i,
  input  wire        rst_ni,
  input  wire        testmode_i,
  input  wire        run_i,
  output wire        adc_sclk_o,           // idles high
  output wire        adc_csn_o,
  input  wire        adc_sdo_i,
  output reg  [13:0] code_o,
  output reg         valid_o
);
  reg  [4:0]  c;
  reg         csn_q, en_q, first_q, sdo_q;
  reg  [14:0] sh;
  wire        idle = (c == 5'd19) && !run_i;           // state 19 is held while there is nothing to do
  wire [4:0]  c_n  = (c == 5'd19) ? 5'd0 : c + 5'd1;
  wire [4:0]  s_lo = (SAMPLE_DLY == 0) ? 5'd1  : 5'd2;  // first and last state of the shift, and the state that stores
  wire [4:0]  s_hi = (SAMPLE_DLY == 0) ? 5'd15 : 5'd16;
  wire [4:0]  s_st = (SAMPLE_DLY == 0) ? 5'd16 : 5'd17;
  wire        sdo_s = (SAMPLE_DLY == 0) ? adc_sdo_i : sdo_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c <= 5'd19; csn_q <= 1'b1; en_q <= 1'b0; first_q <= 1'b1; sdo_q <= 1'b0;
      sh <= 15'd0; code_o <= 14'd0; valid_o <= 1'b0;
    end else begin
      sdo_q   <= adc_sdo_i;
      valid_o <= 1'b0;
      if (idle) begin
        csn_q <= 1'b1; en_q <= 1'b0;
      end else begin
        c     <= c_n;
        csn_q <= ~(c_n <= 5'd18);                      // CS low in states 0..18
        en_q  <=  (c_n <= 5'd17);                      // gate enabled in states 0..17: falling SCLK edges at states 1..18
        if (c_n >= s_lo && c_n <= s_hi) sh <= {sh[13:0], sdo_s};
        if (c_n == s_st) begin code_o <= sh[13:0]; valid_o <= ~first_q; first_q <= 1'b0; end
      end
    end
  end

  // clock gate (library cell, TE keeps the clock running in test mode) and inversion: SCLK idles high
  wire gclk;
  gf180mcu_fd_sc_mcu7t5v0__icgtp_4 u_icg (.CLK(clk_i), .E(en_q), .TE(testmode_i), .Q(gclk));
  assign adc_sclk_o = ~gclk;
  assign adc_csn_o  = csn_q;
endmodule
