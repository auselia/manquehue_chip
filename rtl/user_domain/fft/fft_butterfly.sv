// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Derived from the radix-2 butterfly of FFTodile (ETH Zurich and University of Bologna, Apache-2.0).
// Changes: the twiddle product is rounded (round-half-up) before the add, the halving after the add is
// rounded, and the outputs saturate with a flag.

// One radix-2 DIT butterfly, forward transform, with halving.
//   t   = W * up,  W = c - j s            (c = cos, s = +sin of the angle)
//   lo' = (lo + t) / 2,  up' = (lo - t) / 2

module fft_butterfly (
  input  logic signed [15:0] lo_r_i,
  input  logic signed [15:0] lo_i_i,
  input  logic signed [15:0] up_r_i,
  input  logic signed [15:0] up_i_i,
  input  logic signed [15:0] c_i,
  input  logic signed [15:0] s_i,

  output logic signed [15:0] lo_r_o,
  output logic signed [15:0] lo_i_o,
  output logic signed [15:0] up_r_o,
  output logic signed [15:0] up_i_o,
  output logic               sat_o
);

  logic signed [33:0] pr_full, pi_full;
  logic signed [17:0] pr, pi_;
  logic signed [18:0] sum_r, sum_i, dif_r, dif_i;
  logic signed [17:0] hs_r, hs_i, hd_r, hd_i;

  assign pr_full = 34'(c_i * up_r_i) + 34'(s_i * up_i_i) + 34'sd16384;
  assign pi_full = 34'(c_i * up_i_i) - 34'(s_i * up_r_i) + 34'sd16384;
  assign pr      = pr_full[32:15];
  assign pi_     = pi_full[32:15];

  assign sum_r = 19'(lo_r_i) + 19'(pr) + 19'sd1;
  assign sum_i = 19'(lo_i_i) + 19'(pi_) + 19'sd1;
  assign dif_r = 19'(lo_r_i) - 19'(pr) + 19'sd1;
  assign dif_i = 19'(lo_i_i) - 19'(pi_) + 19'sd1;
  assign hs_r  = sum_r[18:1];
  assign hs_i  = sum_i[18:1];
  assign hd_r  = dif_r[18:1];
  assign hd_i  = dif_i[18:1];

  function automatic logic signed [15:0] clip(input logic signed [17:0] v);
    if (v > 18'sd32767)       clip = 16'sd32767;
    else if (v < -18'sd32768) clip = -16'sd32768;
    else                      clip = v[15:0];
  endfunction

  function automatic logic ovf(input logic signed [17:0] v);
    ovf = (v > 18'sd32767) || (v < -18'sd32768);
  endfunction

  assign lo_r_o = clip(hs_r);
  assign lo_i_o = clip(hs_i);
  assign up_r_o = clip(hd_r);
  assign up_i_o = clip(hd_i);

  assign sat_o = ovf(hs_r) || ovf(hs_i) || ovf(hd_r) || ovf(hd_i);

endmodule
