// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Input stage for one sample: offset, gain with saturation, window, and time-domain energy term.
//   d  = sample - dc
//   g  = clip16(d << gain_shift)
//   xw = (g * w + 2^14) >> 15
//   sq = (g * g) >> 10

module fft_pre (
  input  logic signed [15:0] sample_i,
  input  logic signed [15:0] dc_i,
  input  logic        [3:0]  gain_shift_i,
  input  logic        [14:0] w_i,

  output logic signed [15:0] xw_o,
  output logic        [21:0] sq_o,
  output logic               sat_o
);

  logic signed [16:0] d;
  logic signed [32:0] v;
  logic signed [15:0] g;
  logic signed [31:0] g2;
  logic signed [31:0] gw;
  logic signed [32:0] gw_r;

  assign d = 17'(sample_i) - 17'(dc_i);
  assign v = 33'(d) <<< gain_shift_i;

  always_comb begin
    sat_o = 1'b0;
    if (v > 33'sd32767) begin
      g     = 16'sd32767;
      sat_o = 1'b1;
    end else if (v < -33'sd32768) begin
      g     = -16'sd32768;
      sat_o = 1'b1;
    end else begin
      g = v[15:0];
    end
  end

  assign g2   = g * g;
  assign sq_o = g2[31:10];

  assign gw   = g * $signed({1'b0, w_i});
  assign gw_r = 33'(gw) + 33'sd16384;
  assign xw_o = gw_r[30:15];

endmodule
