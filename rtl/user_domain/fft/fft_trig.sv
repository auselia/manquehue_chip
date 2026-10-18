// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// cos and sin of 2*pi*k/128 for k = 0..64, both from the 33-entry cosine ROM.
//   k <= 32: cos = R[k],        sin = R[32-k]
//   k >  32: cos = -R[64-k],    sin = R[k-32]
// sin is returned positive (the sign of the forward transform is handled in the butterfly).

module fft_trig (
  input  logic        [6:0]  k_i,
  output logic signed [15:0] cos_o,
  output logic signed [15:0] sin_o
);

  logic [6:0] cos_idx, sin_idx;
  logic       cos_neg;
  logic signed [15:0] cos_rom, sin_rom;

  always_comb begin
    if (k_i <= 7'd32) begin
      cos_idx = k_i;
      sin_idx = 7'd32 - k_i;
      cos_neg = 1'b0;
    end else begin
      cos_idx = 7'd64 - k_i;
      sin_idx = k_i - 7'd32;
      cos_neg = 1'b1;
    end
  end

  fft_cos_rom i_cos (.idx_i(cos_idx[5:0]), .val_o(cos_rom));
  fft_cos_rom i_sin (.idx_i(sin_idx[5:0]), .val_o(sin_rom));

  assign cos_o = cos_neg ? -cos_rom : cos_rom;
  assign sin_o = sin_rom;

endmodule
