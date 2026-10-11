// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Real-FFT post-processing for one bin k of the 128-point real spectrum.
// Inputs are Z[k] and Z[64-k] of the 64-point FFT (Z[64] = Z[0]).
//   Xe = (Z[k] + conj(Z[64-k])) / 2
//   Xo = (Z[k] - conj(Z[64-k])) / (2j)
//   X[k] = Xe + W128^k * Xo,  W128^k = c - j s
// Every halving rounds half-up, the twiddle product rounds half-up.  Output is 18-bit signed.

module fft_post (
  input  logic signed [15:0] zr_i,    // Re Z[k]
  input  logic signed [15:0] zi_i,    // Im Z[k]
  input  logic signed [15:0] yr_i,    // Re Z[64-k]
  input  logic signed [15:0] yi_i,    // Im Z[64-k]
  input  logic signed [15:0] c_i,     // cos(2 pi k / 128)
  input  logic signed [15:0] s_i,     // sin(2 pi k / 128), positive

  output logic signed [17:0] xr_o,
  output logic signed [17:0] xi_o
);

  logic signed [17:0] er_f, ei_f, dr_f, di_f;
  logic signed [15:0] er, ei;
  logic signed [16:0] dr, di;
  logic signed [16:0] o_r, o_i;
  logic signed [34:0] tr_full, ti_full;
  logic signed [18:0] tr, ti;

  assign er_f = 18'(zr_i) + 18'(yr_i) + 18'sd1;
  assign ei_f = 18'(zi_i) - 18'(yi_i) + 18'sd1;
  assign dr_f = 18'(zr_i) - 18'(yr_i) + 18'sd1;
  assign di_f = 18'(zi_i) + 18'(yi_i) + 18'sd1;
  assign er   = er_f[16:1];
  assign ei   = ei_f[16:1];
  assign dr   = dr_f[17:1];
  assign di   = di_f[17:1];

  assign o_r = di;
  assign o_i = -dr;

  assign tr_full = 35'(c_i * o_r) + 35'(s_i * o_i) + 35'sd16384;
  assign ti_full = 35'(c_i * o_i) - 35'(s_i * o_r) + 35'sd16384;
  assign tr      = tr_full[33:15];
  assign ti      = ti_full[33:15];

  assign xr_o = 18'(er) + 18'(tr);
  assign xi_o = 18'(ei) + 18'(ti);

endmodule
