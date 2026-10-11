// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Structure follows the iterative radix-2 core of FFTodile (ETH Zurich and University of Bologna).

// AE-FFT accelerator core: 128 real samples in, spectrum features out.
//
//   LOAD  one 32-bit word (two samples) per cycle: offset, gain, window, time-domain energy,
//         write one complex value to the local memory in bit-reversed position
//   FFT   64-point complex radix-2 FFT in place, one butterfly per cycle, 6 stages
//   POST  one bin per cycle, k = 0..64: real-FFT post-processing, then power and features
//   FIN   one cycle: flags and result registers
//
// All results are valid after done_o.  Specification: doc/spec_fft.tex.  Golden model:
// sim/fft/model/aefft_model.py.

module fft_hwpe_core (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,       // pulse, accepted in idle
  input  logic        abort_i,       // returns to idle at once
  input  logic        clr_prev_i,    // pulse: clear PREV_VALID, TD_ENERGY and TD_PREV

  // configuration, must be stable while busy
  input  logic [3:0]  gain_shift_i,
  input  logic [3:0]  en_shift_i,
  input  logic signed [15:0] dc_offset_i,
  input  logic [6:0]  kmin_i,
  input  logic [6:0]  band_lo_i,
  input  logic [6:0]  band_hi_i,
  input  logic [7:0]  band_thr_i,
  input  logic [7:0]  decay_thr_i,
  input  logic        dump_en_i,

  // sample stream: 64 words, sample 2m in [15:0] and 2m+1 in [31:16]
  input  logic        sample_valid_i,
  output logic        sample_ready_o,
  input  logic [31:0] sample_i,

  // dump stream: 65 words {Xr, Xi}, only when dump_en_i
  output logic        result_valid_o,
  input  logic        result_ready_i,
  output logic [31:0] result_o,

  output logic        busy_o,
  output logic        done_o,        // one-cycle pulse

  // results, valid after done_o and until the next start
  output logic        sat_o,
  output logic        prev_valid_o,
  output logic        band_ok_o,
  output logic        decay_o,
  output logic [6:0]  peak_bin_o,
  output logic [31:0] peak_pow_o,
  output logic [31:0] band_energy_o,
  output logic [31:0] total_energy_o,
  output logic [31:0] td_energy_o,
  output logic [31:0] td_prev_o,
  output logic [31:0] cycles_o
);

  typedef enum logic [2:0] {S_IDLE, S_LOAD, S_FFT, S_POST, S_FIN} state_e;
  state_e state_q;

  // --------------------------------------------------------------------------------------------
  // Local memory: 64 complex values, two read ports, two write ports
  // --------------------------------------------------------------------------------------------
  logic signed [15:0] re_mem_q [64];
  logic signed [15:0] im_mem_q [64];

  logic [5:0]  rd_addr0, rd_addr1;
  logic signed [15:0] rd0_r, rd0_i, rd1_r, rd1_i;
  assign rd0_r = re_mem_q[rd_addr0];
  assign rd0_i = im_mem_q[rd_addr0];
  assign rd1_r = re_mem_q[rd_addr1];
  assign rd1_i = im_mem_q[rd_addr1];

  function automatic logic [5:0] bitrev6(input logic [5:0] v);
    for (int i = 0; i < 6; i++) bitrev6[i] = v[5-i];
  endfunction

  // --------------------------------------------------------------------------------------------
  // LOAD stage
  // --------------------------------------------------------------------------------------------
  logic [5:0]  load_cnt_q;           // words accepted
  logic        ld_v_q;               // a word is waiting in the input register
  logic [5:0]  ld_idx_q;
  logic [31:0] ld_word_q;

  assign sample_ready_o = (state_q == S_LOAD);

  logic [6:0]  win_n0, win_n1;
  logic [14:0] win0, win1;
  assign win_n0 = {ld_idx_q, 1'b0};
  assign win_n1 = {ld_idx_q, 1'b1};
  fft_window i_win0 (.n_i(win_n0), .w_o(win0));
  fft_window i_win1 (.n_i(win_n1), .w_o(win1));

  logic signed [15:0] xw0, xw1;
  logic [21:0]        sq0, sq1;
  logic               sat0, sat1;
  fft_pre i_pre0 (.sample_i(ld_word_q[15:0]),  .dc_i(dc_offset_i), .gain_shift_i(gain_shift_i), .w_i(win0),
                  .xw_o(xw0), .sq_o(sq0), .sat_o(sat0));
  fft_pre i_pre1 (.sample_i(ld_word_q[31:16]), .dc_i(dc_offset_i), .gain_shift_i(gain_shift_i), .w_i(win1),
                  .xw_o(xw1), .sq_o(sq1), .sat_o(sat1));

  logic [31:0] td_acc_q;
  logic [33:0] td_sum;
  assign td_sum = 34'(td_acc_q) + 34'(sq0) + 34'(sq1);

  // --------------------------------------------------------------------------------------------
  // FFT stage
  // --------------------------------------------------------------------------------------------
  logic [2:0]  stage_q;
  logic [6:0]  group_q;
  logic [5:0]  bf_q;
  logic [5:0]  half;
  logic [6:0]  span;
  logic [5:0]  lower, upper;
  logic [6:0]  tw_k;
  logic        last_bf, last_group, last_stage;

  assign half       = 6'd1 << stage_q;
  assign span       = 7'(half) << 1;
  assign lower      = group_q[5:0] + bf_q;
  assign upper      = lower + half;
  assign tw_k       = 7'(bf_q) << (3'd6 - stage_q);        // k of W128^k, even
  assign last_bf    = (bf_q == half - 6'd1);
  assign last_group = (group_q == (7'd64 - span));
  assign last_stage = (stage_q == 3'd5);

  logic signed [15:0] tw_c, tw_s;
  logic [6:0]         trig_k;
  fft_trig i_trig (.k_i(trig_k), .cos_o(tw_c), .sin_o(tw_s));

  logic signed [15:0] b_lo_r, b_lo_i, b_up_r, b_up_i;
  logic               b_sat;
  fft_butterfly i_bf (.lo_r_i(rd0_r), .lo_i_i(rd0_i), .up_r_i(rd1_r), .up_i_i(rd1_i), .c_i(tw_c), .s_i(tw_s),
                      .lo_r_o(b_lo_r), .lo_i_o(b_lo_i), .up_r_o(b_up_r), .up_i_o(b_up_i), .sat_o(b_sat));

  // --------------------------------------------------------------------------------------------
  // POST stage: issue bin ka_q, register X, then power and features on the registered value
  // --------------------------------------------------------------------------------------------
  logic [6:0]  ka_q;                   // next bin to compute, 0..64, 65 = all issued
  logic        xv_q;
  logic [6:0]  xk_q;
  logic signed [17:0] xr_q, xi_q;
  logic signed [17:0] post_xr, post_xi;
  logic        advance;
  logic        post_issue;

  fft_post i_post (.zr_i(rd0_r), .zi_i(rd0_i), .yr_i(rd1_r), .yi_i(rd1_i), .c_i(tw_c), .s_i(tw_s),
                   .xr_o(post_xr), .xi_o(post_xi));

  assign advance        = !(xv_q && dump_en_i && !result_ready_i);
  assign post_issue     = (state_q == S_POST) && (ka_q <= 7'd64);

  function automatic logic signed [15:0] sat16(input logic signed [17:0] v);
    if (v > 18'sd32767)       sat16 = 16'sd32767;
    else if (v < -18'sd32768) sat16 = -16'sd32768;
    else                      sat16 = v[15:0];
  endfunction

  logic x_sat;
  assign x_sat          = (sat16(xr_q) != xr_q[15:0]) || (xr_q[17:16] != {2{xr_q[15]}}) ||
                          (sat16(xi_q) != xi_q[15:0]) || (xi_q[17:16] != {2{xi_q[15]}});
  assign result_valid_o = (state_q == S_POST) && xv_q && dump_en_i;
  assign result_o       = {sat16(xr_q), sat16(xi_q)};

  logic        feat_init;
  logic        feat_valid;
  logic [6:0]  f_peak;
  logic [31:0] f_peak_pow, f_band, f_total;
  logic        f_sat;
  assign feat_init  = (state_q == S_IDLE) && start_i;
  assign feat_valid = (state_q == S_POST) && xv_q && advance;

  fft_feat i_feat (
    .clk_i, .rst_ni,
    .init_i      ( feat_init  ),
    .valid_i     ( feat_valid ),
    .k_i         ( xk_q       ),
    .xr_i        ( xr_q       ),
    .xi_i        ( xi_q       ),
    .en_shift_i  ( en_shift_i ),
    .kmin_i      ( kmin_i     ),
    .band_lo_i   ( band_lo_i  ),
    .band_hi_i   ( band_hi_i  ),
    .peak_bin_o  ( f_peak     ),
    .peak_pow_o  ( f_peak_pow ),
    .band_o      ( f_band     ),
    .total_o     ( f_total    ),
    .sat_o       ( f_sat      )
  );

  // --------------------------------------------------------------------------------------------
  // Shared read addresses and twiddle index
  // --------------------------------------------------------------------------------------------
  always_comb begin
    rd_addr0 = lower;
    rd_addr1 = upper;
    trig_k   = tw_k;
    if (state_q == S_POST) begin
      rd_addr0 = ka_q[5:0];
      rd_addr1 = 6'd0 - ka_q[5:0];
      trig_k   = ka_q;
    end
  end

  // --------------------------------------------------------------------------------------------
  // Flags at the end of a run
  // --------------------------------------------------------------------------------------------
  logic [31:0] td_q, tdp_q;
  logic        prev_valid_q;
  logic        band_ok_q, decay_q, sat_q;
  logic [39:0] band_x256, total_x_thr, td_x256, tdp_x_thr;
  assign band_x256   = {f_band, 8'd0};
  assign total_x_thr = 40'(f_total) * 40'(band_thr_i);
  assign td_x256     = {td_acc_q, 8'd0};
  assign tdp_x_thr   = 40'(td_q) * 40'(decay_thr_i);

  logic [31:0] cycle_q, cycles_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      load_cnt_q   <= '0;
      ld_v_q       <= 1'b0;
      ld_idx_q     <= '0;
      ld_word_q    <= '0;
      td_acc_q     <= '0;
      stage_q      <= '0;
      group_q      <= '0;
      bf_q         <= '0;
      ka_q         <= '0;
      xv_q         <= 1'b0;
      xk_q         <= '0;
      xr_q         <= '0;
      xi_q         <= '0;
      td_q         <= '0;
      tdp_q        <= '0;
      prev_valid_q <= 1'b0;
      band_ok_q    <= 1'b0;
      decay_q      <= 1'b0;
      sat_q        <= 1'b0;
      cycle_q      <= '0;
      cycles_q     <= '0;
      done_o       <= 1'b0;
    end else begin
      done_o <= 1'b0;

      if (clr_prev_i && state_q == S_IDLE) begin
        prev_valid_q <= 1'b0;
        td_q         <= '0;
        tdp_q        <= '0;
      end

      if (state_q != S_IDLE) cycle_q <= cycle_q + 1'b1;

      unique case (state_q)
        S_IDLE: begin
          if (start_i) begin
            state_q    <= S_LOAD;
            load_cnt_q <= '0;
            ld_v_q     <= 1'b0;
            td_acc_q   <= '0;
            stage_q    <= '0;
            group_q    <= '0;
            bf_q       <= '0;
            ka_q       <= '0;
            xv_q       <= 1'b0;
            sat_q      <= 1'b0;
            cycle_q    <= 32'd1;
          end
        end

        S_LOAD: begin
          // stage 1: input register
          ld_v_q <= sample_valid_i;
          if (sample_valid_i) begin
            ld_word_q  <= sample_i;
            ld_idx_q   <= load_cnt_q;
            load_cnt_q <= load_cnt_q + 1'b1;
          end
          // stage 2: offset, gain, window, write
          if (ld_v_q) begin
            re_mem_q[bitrev6(ld_idx_q)] <= xw0;
            im_mem_q[bitrev6(ld_idx_q)] <= xw1;
            td_acc_q <= td_sum[33:32] != 2'b00 ? 32'hFFFF_FFFF : td_sum[31:0];
            if (sat0 || sat1 || td_sum[33:32] != 2'b00) sat_q <= 1'b1;
            if (ld_idx_q == 6'd63) state_q <= S_FFT;
          end
        end

        S_FFT: begin
          re_mem_q[lower] <= b_lo_r;
          im_mem_q[lower] <= b_lo_i;
          re_mem_q[upper] <= b_up_r;
          im_mem_q[upper] <= b_up_i;
          if (b_sat) sat_q <= 1'b1;
          if (last_bf) begin
            bf_q <= '0;
            if (last_group) begin
              group_q <= '0;
              if (last_stage) begin
                state_q <= S_POST;
                ka_q    <= '0;
                xv_q    <= 1'b0;
              end else begin
                stage_q <= stage_q + 1'b1;
              end
            end else begin
              group_q <= group_q + span;
            end
          end else begin
            bf_q <= bf_q + 1'b1;
          end
        end

        S_POST: begin
          if (advance) begin
            xv_q <= post_issue;
            if (post_issue) begin
              xk_q <= ka_q;
              xr_q <= post_xr;
              xi_q <= post_xi;
              ka_q <= ka_q + 1'b1;
            end
            if (xv_q && x_sat) sat_q <= 1'b1;
            if (xv_q && xk_q == 7'd64) state_q <= S_FIN;
          end
        end

        S_FIN: begin
          band_ok_q    <= (band_x256 >= total_x_thr);
          decay_q      <= prev_valid_q && (td_x256 < tdp_x_thr);
          if (f_sat) sat_q <= 1'b1;
          tdp_q        <= td_q;
          td_q         <= td_acc_q;
          prev_valid_q <= 1'b1;
          cycles_q     <= cycle_q;
          done_o       <= 1'b1;
          state_q      <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase

      if (abort_i) begin
        state_q <= S_IDLE;
        xv_q    <= 1'b0;
        ld_v_q  <= 1'b0;
      end
    end
  end

  assign busy_o         = (state_q != S_IDLE);
  assign sat_o          = sat_q;
  assign prev_valid_o   = prev_valid_q;
  assign band_ok_o      = band_ok_q;
  assign decay_o        = decay_q;
  assign peak_bin_o     = f_peak;
  assign peak_pow_o     = f_peak_pow;
  assign band_energy_o  = f_band;
  assign total_energy_o = f_total;
  assign td_energy_o    = td_q;
  assign td_prev_o      = tdp_q;
  assign cycles_o       = cycles_q;

endmodule
