// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Feature unit: power per bin, peak search, band and total energy.
//   P[k] = min((Xr^2 + Xi^2) >> en_shift, 2^32 - 1)
// Bins arrive in ascending order, one per valid cycle.  Only k >= kmin counts.  The lowest bin wins a tie.
// The 32-bit sums saturate; sat_o is sticky until init_i.

module fft_feat (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        init_i,
  input  logic        valid_i,
  input  logic [6:0]  k_i,
  input  logic signed [17:0] xr_i,
  input  logic signed [17:0] xi_i,

  input  logic [3:0]  en_shift_i,
  input  logic [6:0]  kmin_i,
  input  logic [6:0]  band_lo_i,
  input  logic [6:0]  band_hi_i,

  output logic [6:0]  peak_bin_o,
  output logic [31:0] peak_pow_o,
  output logic [31:0] band_o,
  output logic [31:0] total_o,
  output logic        sat_o
);

  logic [35:0] xr2, xi2;
  logic [36:0] pw_full;
  logic [36:0] pw_sh;
  logic [31:0] pw;
  logic        pw_sat;
  logic        counted, in_band;
  logic        first_q;
  logic [32:0] band_sum, total_sum;

  assign xr2     = xr_i * xr_i;
  assign xi2     = xi_i * xi_i;
  assign pw_full = 37'(xr2) + 37'(xi2);
  assign pw_sh   = pw_full >> en_shift_i;
  assign pw_sat  = |pw_sh[36:32];
  assign pw      = pw_sat ? 32'hFFFF_FFFF : pw_sh[31:0];

  assign counted = valid_i && (k_i >= kmin_i);
  assign in_band = (k_i >= band_lo_i) && (k_i <= band_hi_i);

  assign band_sum  = 33'(band_o)  + 33'(pw);
  assign total_sum = 33'(total_o) + 33'(pw);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      peak_bin_o <= '0;
      peak_pow_o <= '0;
      band_o     <= '0;
      total_o    <= '0;
      sat_o      <= 1'b0;
      first_q    <= 1'b1;
    end else if (init_i) begin
      peak_bin_o <= kmin_i;
      peak_pow_o <= '0;
      band_o     <= '0;
      total_o    <= '0;
      sat_o      <= 1'b0;
      first_q    <= 1'b1;
    end else if (counted) begin
      if (first_q || pw > peak_pow_o) begin
        peak_bin_o <= k_i;
        peak_pow_o <= pw;
      end
      first_q <= 1'b0;
      total_o <= total_sum[32] ? 32'hFFFF_FFFF : total_sum[31:0];
      if (in_band) band_o <= band_sum[32] ? 32'hFFFF_FFFF : band_sum[31:0];
      if (pw_sat || total_sum[32] || (in_band && band_sum[32])) sat_o <= 1'b1;
    end
  end

endmodule
