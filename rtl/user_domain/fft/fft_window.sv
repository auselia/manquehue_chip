// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Periodic Hann window value, Q15, for sample index n = 0..127:
//   w[n] = (32768 - cos(2*pi*n/128)) >> 1,  folded with cos(n) = cos(128-n).
// Range 0..32767.

module fft_window (
  input  logic [6:0]  n_i,
  output logic [14:0] w_o
);

  logic [6:0] fold;
  logic signed [15:0] c;
  logic signed [17:0] diff;

  assign fold = (n_i > 7'd64) ? (~n_i + 7'd1) : n_i;        // 128 - n_i modulo 128: 127 -> 1, 65 -> 63

  fft_trig i_trig (.k_i(fold), .cos_o(c), .sin_o());

  assign diff = 18'sd32768 - 18'(c);
  assign w_o  = diff[15:1];

endmodule
