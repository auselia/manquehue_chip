// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Sequencing and the bus interface follow the structure of FFTodile (ETH Zurich and University of
// Bologna): load, compute, store, with one reusable butterfly datapath.

// AE-FFT accelerator core, minimum-area version.
//
// 128 real samples (two per 32-bit word, 64 words) are transformed in place in the system SRAM.
// There is no local data memory and one 16 x 16 serial multiplier.  Every step takes as long as it needs:
//
//   WIN   per word: offset, gain, window and time-domain energy         (4 products per word)
//   FFT   64-point complex radix-2 DIF in place, 6 stages, 32 butterflies per stage (4 products each)
//   POST  per bin k = 0..64: real-FFT post-processing, power, features   (6 products per bin)
//   FLAGS two products (BAND_OK and DECAY compares)
//
// The model sim/fft/model/aefft_model.py defines every numeric step; the RTL matches it bit for bit.
// A run takes about 27 000 clock cycles (1.4 ms at 20 MHz).  The SRAM is accessed one word at a time.

module fft_hwpe_core
  import croc_pkg::*;
#(
  parameter int unsigned IdxW = $clog2(NumSramBanks * SramBankNumWords)   // word index width of the SRAM
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,       // pulse, accepted in idle
  input  logic        clr_prev_i,    // pulse in idle: clear PREV_VALID, TD_ENERGY and TD_PREV

  // configuration, stable while busy
  input  logic [IdxW-1:0]    src_idx_i,
  input  logic [3:0]         gain_shift_i,
  input  logic [3:0]         en_shift_i,
  input  logic signed [15:0] dc_offset_i,
  input  logic [6:0]         kmin_i,
  input  logic [6:0]         band_lo_i,
  input  logic [6:0]         band_hi_i,
  input  logic [7:0]         band_thr_i,
  input  logic [7:0]         decay_thr_i,

  // OBI manager: one request at a time
  output mgr_obi_req_t obi_mgr_req_o,
  input  mgr_obi_rsp_t obi_mgr_rsp_i,

  output logic        busy_o,
  output logic        done_o,        // one-cycle pulse, run finished
  output logic        error_o,       // one-cycle pulse, run aborted by a bus error

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
  output logic [15:0] cycles_o
);

  localparam logic [31:0] SramBase = get_croc_start_addr(XbarBank0);

  typedef enum logic [4:0] {
    S_IDLE,
    S_W_RD, S_W_DC, S_W_GAIN, S_W_MUL1, S_W_MUL2, S_W_WR,
    S_F_RD0, S_F_RD1, S_F_WRS, S_F_DIFF, S_F_M1, S_F_M2, S_F_M3, S_F_M4, S_F_WRU,
    S_P_RD0, S_P_RD1, S_P_PREP, S_P_M1, S_P_M2, S_P_M3, S_P_M4, S_P_M5, S_P_M6,
    S_N_M1, S_N_M2, S_FIN, S_ERR
  } state_e;

  state_e state_q;

  // --------------------------------------------------------------------------------------------
  // datapath registers (no reset: every one is written before it is read)
  // --------------------------------------------------------------------------------------------
  logic signed [15:0] r0_r_q, r0_i_q, r1_r_q, r1_i_q;
  logic signed [39:0] mul_a_q;          // multiplicand, shifts left
  logic        [15:0] mul_b_q;          // multiplier, shifts right
  logic signed [39:0] acc_q;
  logic [3:0]         mul_cnt_q;
  logic               mul_busy_q;
  logic               mul_sub_q;
  logic [3:0]         gcnt_q;           // doublings left in the gain loop
  logic               started_q;        // the multiplier was started in this state
  logic               gnt_q;            // the request of this state was granted

  // control registers
  logic [6:0]  m_q;                     // word index (0..63) or bin index (0..64)
  logic        j_q;                     // sample within a word
  logic [4:0]  i_q;                     // butterfly index within a stage
  logic [2:0]  s_q;                     // stage
  logic [15:0] cycle_q;

  // results
  logic [31:0] td_q, tdp_q, band_q, total_q, peak_pow_q;
  logic [6:0]  peak_bin_q;
  logic        prev_valid_q, band_ok_q, decay_q, sat_q, first_q;

  // --------------------------------------------------------------------------------------------
  // helpers
  // --------------------------------------------------------------------------------------------
  function automatic logic [5:0] bitrev6(input logic [5:0] v);
    for (int k = 0; k < 6; k++) bitrev6[k] = v[5-k];
  endfunction

  function automatic logic signed [15:0] clip16(input logic signed [31:0] v);
    if (v > 32'sd32767)       clip16 = 16'sd32767;
    else if (v < -32'sd32768) clip16 = -16'sd32768;
    else                      clip16 = v[15:0];
  endfunction

  function automatic logic ovf16(input logic signed [31:0] v);
    ovf16 = (v > 32'sd32767) || (v < -32'sd32768);
  endfunction

  // --------------------------------------------------------------------------------------------
  // twiddle and window values from the one cosine ROM
  // --------------------------------------------------------------------------------------------
  logic [5:0]  half_w;                  // butterfly: 32 >> stage
  logic [4:0]  bfly_b;
  logic [5:0]  lo6, up6;
  logic [6:0]  trig_k;
  logic signed [15:0] tw_c, tw_s;
  logic [6:0]  win_n, win_fold;
  logic [14:0] win_w;
  logic signed [17:0] win_diff;

  always_comb begin
    half_w = 6'd32 >> s_q;
    bfly_b = i_q & 5'(half_w - 6'd1);
    lo6    = {(i_q & ~5'(half_w - 6'd1)), 1'b0} | {1'b0, bfly_b};
    up6    = lo6 | half_w;
    win_n    = {m_q[5:0], j_q};
    win_fold = (win_n > 7'd64) ? (~win_n + 7'd1) : win_n;
    unique case (state_q)
      S_W_MUL1, S_W_MUL2: trig_k = win_fold;
      S_P_M1, S_P_M2, S_P_M3, S_P_M4: trig_k = m_q;
      default: trig_k = {1'b0, bfly_b, 1'b0} << s_q;            // b << (stage + 1), even, below 64
    endcase
  end

  fft_trig i_trig (.k_i(trig_k), .cos_o(tw_c), .sin_o(tw_s));

  assign win_diff = 18'sd32768 - 18'(tw_c);
  assign win_w    = win_diff[15:1];

  // --------------------------------------------------------------------------------------------
  // sample conditioning (window pass): g = clip16((x - dc) << gain_shift), done as one subtract and
  // GAIN_SHIFT doublings, each with a clip.  A clipped value stays clipped, so this equals one clip of the
  // full shift.
  // --------------------------------------------------------------------------------------------
  logic signed [15:0] g_val;            // the conditioned sample is kept in r0, selected by j
  assign g_val = j_q ? r0_i_q : r0_r_q;

  logic signed [31:0] gx_dc, gx_dbl;
  logic signed [15:0] g_dc_c, g_dbl_c;
  logic               g_dc_ovf, g_dbl_ovf;
  assign gx_dc    = 32'(g_val) - 32'(dc_offset_i);
  assign gx_dbl   = 32'(g_val) <<< 1;
  assign g_dc_c   = clip16(gx_dc);
  assign g_dbl_c  = clip16(gx_dbl);
  assign g_dc_ovf = ovf16(gx_dc);
  assign g_dbl_ovf= ovf16(gx_dbl);

  // --------------------------------------------------------------------------------------------
  // butterfly and post-processing arithmetic on r0 and r1
  // --------------------------------------------------------------------------------------------
  logic signed [31:0] sum_r_f, sum_i_f, dif_r_f, dif_i_f;
  logic signed [15:0] sum_r, sum_i, dif_r, dif_i;
  assign sum_r_f = (32'(r0_r_q) + 32'(r1_r_q) + 32'sd1) >>> 1;
  assign sum_i_f = (32'(r0_i_q) + 32'(r1_i_q) + 32'sd1) >>> 1;
  assign dif_r_f = (32'(r0_r_q) - 32'(r1_r_q) + 32'sd1) >>> 1;
  assign dif_i_f = (32'(r0_i_q) - 32'(r1_i_q) + 32'sd1) >>> 1;
  assign sum_r = clip16(sum_r_f);
  assign sum_i = clip16(sum_i_f);
  assign dif_r = clip16(dif_r_f);
  assign dif_i = clip16(dif_i_f);

  // post-processing preparation reuses the same sums: Xe = (Z[k] + conj Z[64-k]) / 2 -> er = sum_r, ei = dif_i,
  // and Xo * j = (Z[k] - conj Z[64-k]) / 2 -> Re = (Im Z + Im Z') / 2 = sum_i, Im = -(Re Z - Re Z') / 2 = -dif_r.
  // (ei, pdr use the difference of the imaginary and real parts respectively, see S_P_PREP.)

  // --------------------------------------------------------------------------------------------
  // multiplier operands per state
  // --------------------------------------------------------------------------------------------
  logic              is_mul_state;
  logic signed [39:0] mul_a_val;
  logic        [15:0] mul_b_val;
  logic        [1:0]  mul_init;         // 0: acc = 0, 1: acc = 2^14, 2: keep
  logic               mul_sub;          // subtract the product instead of adding it

  always_comb begin
    is_mul_state = 1'b1;
    mul_a_val    = '0;
    mul_b_val    = '0;
    mul_init     = 2'd0;
    mul_sub      = 1'b0;
    unique case (state_q)
      S_W_MUL1: begin mul_a_val = 40'(g_val);  mul_b_val = 16'(g_val);               mul_init = 2'd0; end
      S_W_MUL2: begin mul_a_val = 40'(g_val);  mul_b_val = {1'b0, win_w};            mul_init = 2'd1; end
      S_F_M1:   begin mul_a_val = 40'(r0_r_q); mul_b_val = 16'(tw_c);                mul_init = 2'd1; end
      S_F_M2:   begin mul_a_val = 40'(r0_i_q); mul_b_val = 16'(tw_s);                mul_init = 2'd2; end
      S_F_M3:   begin mul_a_val = 40'(r0_i_q); mul_b_val = 16'(tw_c);                mul_init = 2'd1; end
      S_F_M4:   begin mul_a_val = 40'(r0_r_q); mul_b_val = 16'(tw_s);                mul_init = 2'd2; mul_sub = 1'b1; end
      S_P_M1:   begin mul_a_val = 40'(r1_r_q); mul_b_val = 16'(tw_c);                mul_init = 2'd1; end
      S_P_M2:   begin mul_a_val = 40'(r1_i_q); mul_b_val = 16'(tw_s);                mul_init = 2'd2; end
      S_P_M3:   begin mul_a_val = 40'(r1_i_q); mul_b_val = 16'(tw_c);                mul_init = 2'd1; end
      S_P_M4:   begin mul_a_val = 40'(r1_r_q); mul_b_val = 16'(tw_s);                mul_init = 2'd2; mul_sub = 1'b1; end
      S_P_M5:   begin mul_a_val = 40'(r0_r_q); mul_b_val = 16'(r0_r_q);              mul_init = 2'd0; end
      S_P_M6:   begin mul_a_val = 40'(r0_i_q); mul_b_val = 16'(r0_i_q);              mul_init = 2'd2; end
      S_N_M1:   begin mul_a_val = {8'h00, total_q}; mul_b_val = {8'h00, band_thr_i}; mul_init = 2'd0; end
      S_N_M2:   begin mul_a_val = {8'h00, tdp_q};   mul_b_val = {8'h00, decay_thr_i}; mul_init = 2'd0; end
      default:  is_mul_state = 1'b0;
    endcase
  end

  // --------------------------------------------------------------------------------------------
  // bus access
  // --------------------------------------------------------------------------------------------
  logic        acc_req, acc_we;
  logic [IdxW-1:0] acc_idx;
  logic [31:0] acc_wdata;
  logic [IdxW-1:0] src_plus_m, src_plus_lo, src_plus_up, src_plus_br0, src_plus_br1;
  logic [5:0]  m_neg;
  assign m_neg        = 6'd0 - m_q[5:0];
  assign src_plus_m   = src_idx_i + IdxW'(m_q[5:0]);
  assign src_plus_lo  = src_idx_i + IdxW'(lo6);
  assign src_plus_up  = src_idx_i + IdxW'(up6);
  assign src_plus_br0 = src_idx_i + IdxW'(bitrev6(m_q[5:0]));
  assign src_plus_br1 = src_idx_i + IdxW'(bitrev6(m_neg));

  always_comb begin
    acc_req   = 1'b0;
    acc_we    = 1'b0;
    acc_idx   = src_plus_m;
    acc_wdata = {r0_i_q, r0_r_q};
    unique case (state_q)
      S_W_RD:  begin acc_req = 1'b1; acc_idx = src_plus_m;   end
      S_W_WR:  begin acc_req = 1'b1; acc_idx = src_plus_m;   acc_we = 1'b1; acc_wdata = {r0_i_q, r0_r_q}; end
      S_F_RD0: begin acc_req = 1'b1; acc_idx = src_plus_lo;  end
      S_F_RD1: begin acc_req = 1'b1; acc_idx = src_plus_up;  end
      S_F_WRS: begin acc_req = 1'b1; acc_idx = src_plus_lo;  acc_we = 1'b1; acc_wdata = {sum_i, sum_r}; end
      S_F_WRU: begin acc_req = 1'b1; acc_idx = src_plus_up;  acc_we = 1'b1; acc_wdata = {r1_i_q, r1_r_q}; end
      S_P_RD0: begin acc_req = 1'b1; acc_idx = src_plus_br0; end
      S_P_RD1: begin acc_req = 1'b1; acc_idx = src_plus_br1; end
      default: ;
    endcase
  end

  assign obi_mgr_req_o.req          = acc_req && !gnt_q;
  assign obi_mgr_req_o.a.addr       = SramBase | (32'(acc_idx) << 2);
  assign obi_mgr_req_o.a.we         = acc_we;
  assign obi_mgr_req_o.a.be         = 4'hF;
  assign obi_mgr_req_o.a.wdata      = acc_wdata;
  assign obi_mgr_req_o.a.aid        = '0;
  assign obi_mgr_req_o.a.a_optional = 1'b0;

  logic rsp_valid, rsp_err;
  assign rsp_valid = acc_req && gnt_q && obi_mgr_rsp_i.rvalid;
  assign rsp_err   = rsp_valid && obi_mgr_rsp_i.r.err;

  // --------------------------------------------------------------------------------------------
  // final-pass helpers
  // --------------------------------------------------------------------------------------------
  logic [31:0] p_val;
  logic [32:0] total_sum, band_sum;
  logic        in_band, counted;
  logic [39:0] band_x256, td_x256;
  assign p_val     = acc_q[31:0] >> en_shift_i;
  assign counted   = (m_q >= kmin_i);
  assign in_band   = (m_q >= band_lo_i) && (m_q <= band_hi_i);
  assign total_sum = 33'(total_q) + 33'(p_val);
  assign band_sum  = 33'(band_q) + 33'(p_val);
  assign band_x256 = {band_q, 8'h00};
  assign td_x256   = {td_q, 8'h00};

  logic signed [31:0] prod_hi;
  assign prod_hi = 32'($signed(acc_q[39:15]));      // product >> 15, sign extended

  logic [32:0] td_sum;
  assign td_sum = 33'(td_q) + 33'(acc_q[31:10]);

  // --------------------------------------------------------------------------------------------
  // main sequencer
  // --------------------------------------------------------------------------------------------
  logic mul_done;
  assign mul_done = started_q && !mul_busy_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      started_q    <= 1'b0;
      gnt_q        <= 1'b0;
      mul_busy_q   <= 1'b0;
      mul_cnt_q    <= '0;
      m_q          <= '0;
      j_q          <= 1'b0;
      i_q          <= '0;
      s_q          <= '0;
      cycle_q      <= '0;
      prev_valid_q <= 1'b0;
      band_ok_q    <= 1'b0;
      decay_q      <= 1'b0;
      sat_q        <= 1'b0;
      first_q      <= 1'b1;
      td_q         <= '0;
      tdp_q        <= '0;
      band_q       <= '0;
      total_q      <= '0;
      peak_pow_q   <= '0;
      peak_bin_q   <= '0;
      done_o       <= 1'b0;
      error_o      <= 1'b0;
    end else begin
      done_o  <= 1'b0;
      error_o <= 1'b0;

      // serial multiplier: one multiplier bit per cycle, sign bit subtracts
      if (mul_busy_q) begin
        if (mul_b_q[0]) begin
          if ((mul_cnt_q == 4'd15) ^ mul_sub_q) acc_q <= acc_q - mul_a_q;
          else                                  acc_q <= acc_q + mul_a_q;
        end
        mul_a_q   <= mul_a_q <<< 1;
        mul_b_q   <= mul_b_q >> 1;
        mul_cnt_q <= mul_cnt_q + 4'd1;
        if (mul_cnt_q == 4'd15) mul_busy_q <= 1'b0;
      end

      if (state_q != S_IDLE && cycle_q != 16'hFFFF) cycle_q <= cycle_q + 16'd1;

      // start the multiplier on the first cycle of a multiply state
      if (is_mul_state && !started_q) begin
        started_q  <= 1'b1;
        mul_busy_q <= 1'b1;
        mul_cnt_q  <= 4'd0;
        mul_a_q    <= mul_a_val;
        mul_b_q    <= mul_b_val;
        mul_sub_q  <= mul_sub;
        unique case (mul_init)
          2'd0:    acc_q <= '0;
          2'd1:    acc_q <= 40'sd16384;
          default: ;
        endcase
      end

      // bus request: remember the grant, then wait for the response
      if (acc_req && !gnt_q && obi_mgr_rsp_i.gnt) gnt_q <= 1'b1;
      if (rsp_valid) gnt_q <= 1'b0;

      if (rsp_err) begin
        state_q <= S_ERR;
      end else begin
        unique case (state_q)
          S_IDLE: begin
            if (clr_prev_i) begin
              prev_valid_q <= 1'b0;
              td_q         <= '0;
              tdp_q        <= '0;
            end
            if (start_i) begin
              state_q    <= S_W_RD;
              m_q        <= '0;
              j_q        <= 1'b0;
              i_q        <= '0;
              s_q        <= '0;
              sat_q      <= 1'b0;
              first_q    <= 1'b1;
              tdp_q      <= clr_prev_i ? 32'd0 : td_q;   // CLR_PREV together with START
              td_q       <= '0;
              band_q     <= '0;
              total_q    <= '0;
              peak_pow_q <= '0;
              peak_bin_q <= kmin_i;
              cycle_q    <= 16'd1;
            end
          end

          // ---------------------------------------------------------------- window pass
          S_W_RD: if (rsp_valid) begin
            r0_r_q  <= obi_mgr_rsp_i.r.rdata[15:0];
            r0_i_q  <= obi_mgr_rsp_i.r.rdata[31:16];
            state_q <= S_W_DC;
          end

          S_W_DC: begin                           // x - dc, clipped
            if (j_q) r0_i_q <= g_dc_c;
            else     r0_r_q <= g_dc_c;
            if (g_dc_ovf) sat_q <= 1'b1;
            gcnt_q  <= gain_shift_i;
            state_q <= S_W_GAIN;
          end

          S_W_GAIN: begin                         // GAIN_SHIFT doublings with clip
            if (gcnt_q == 4'd0) begin
              state_q   <= S_W_MUL1;
              started_q <= 1'b0;
            end else begin
              if (j_q) r0_i_q <= g_dbl_c;
              else     r0_r_q <= g_dbl_c;
              if (g_dbl_ovf) sat_q <= 1'b1;
              gcnt_q <= gcnt_q - 4'd1;
            end
          end

          S_W_MUL1: if (mul_done) begin
            td_q      <= td_sum[32] ? 32'hFFFF_FFFF : td_sum[31:0];
            if (td_sum[32]) sat_q <= 1'b1;
            state_q   <= S_W_MUL2;
            started_q <= 1'b0;
          end

          S_W_MUL2: if (mul_done) begin
            if (j_q) r0_i_q <= acc_q[30:15];
            else     r0_r_q <= acc_q[30:15];
            started_q <= 1'b0;
            if (j_q) begin
              j_q     <= 1'b0;
              state_q <= S_W_WR;
            end else begin
              j_q     <= 1'b1;
              state_q <= S_W_DC;
            end
          end

          S_W_WR: if (rsp_valid) begin
            m_q <= m_q + 7'd1;
            if (m_q == 7'd63) begin
              m_q     <= '0;
              state_q <= S_F_RD0;
            end else begin
              state_q <= S_W_RD;
            end
          end

          // ---------------------------------------------------------------- FFT, in place DIF
          S_F_RD0: if (rsp_valid) begin
            r0_r_q  <= obi_mgr_rsp_i.r.rdata[15:0];
            r0_i_q  <= obi_mgr_rsp_i.r.rdata[31:16];
            state_q <= S_F_RD1;
          end

          S_F_RD1: if (rsp_valid) begin
            r1_r_q  <= obi_mgr_rsp_i.r.rdata[15:0];
            r1_i_q  <= obi_mgr_rsp_i.r.rdata[31:16];
            state_q <= S_F_WRS;
          end

          S_F_WRS: if (rsp_valid) begin
            if (ovf16(sum_r_f) || ovf16(sum_i_f)) sat_q <= 1'b1;
            state_q <= S_F_DIFF;
          end

          S_F_DIFF: begin
            r0_r_q    <= dif_r;
            r0_i_q    <= dif_i;
            if (ovf16(dif_r_f) || ovf16(dif_i_f)) sat_q <= 1'b1;
            state_q   <= S_F_M1;
            started_q <= 1'b0;
          end

          S_F_M1: if (mul_done) begin state_q <= S_F_M2; started_q <= 1'b0; end

          S_F_M2: if (mul_done) begin
            r1_r_q    <= clip16(prod_hi);
            if (ovf16(prod_hi)) sat_q <= 1'b1;
            state_q   <= S_F_M3;
            started_q <= 1'b0;
          end

          S_F_M3: if (mul_done) begin state_q <= S_F_M4; started_q <= 1'b0; end

          S_F_M4: if (mul_done) begin
            r1_i_q  <= clip16(prod_hi);
            if (ovf16(prod_hi)) sat_q <= 1'b1;
            state_q <= S_F_WRU;
          end

          S_F_WRU: if (rsp_valid) begin
            if (i_q == 5'd31) begin
              i_q <= '0;
              if (s_q == 3'd5) begin
                s_q     <= '0;
                m_q     <= '0;
                state_q <= S_P_RD0;
              end else begin
                s_q     <= s_q + 3'd1;
                state_q <= S_F_RD0;
              end
            end else begin
              i_q     <= i_q + 5'd1;
              state_q <= S_F_RD0;
            end
          end

          // ---------------------------------------------------------------- post-processing
          S_P_RD0: if (rsp_valid) begin
            r0_r_q  <= obi_mgr_rsp_i.r.rdata[15:0];
            r0_i_q  <= obi_mgr_rsp_i.r.rdata[31:16];
            state_q <= S_P_RD1;
          end

          S_P_RD1: if (rsp_valid) begin
            r1_r_q  <= obi_mgr_rsp_i.r.rdata[15:0];
            r1_i_q  <= obi_mgr_rsp_i.r.rdata[31:16];
            state_q <= S_P_PREP;
          end

          S_P_PREP: begin
            r0_r_q  <= sum_r;                     // Xe real = (Re Z + Re Z') / 2
            r0_i_q  <= dif_i;                     // Xe imag = (Im Z - Im Z') / 2
            r1_r_q  <= sum_i;                     // Xo real = (Im Z + Im Z') / 2, clipped
            r1_i_q  <= -dif_r;                    // Xo imag = -(Re Z - Re Z') / 2, clipped
            if (ovf16(dif_r_f) || ovf16(sum_i_f)) sat_q <= 1'b1;
            state_q   <= S_P_M1;
            started_q <= 1'b0;
          end

          S_P_M1: if (mul_done) begin state_q <= S_P_M2; started_q <= 1'b0; end

          S_P_M2: if (mul_done) begin
            r0_r_q <= clip16(32'(r0_r_q) + prod_hi);
            if (ovf16(32'(r0_r_q) + prod_hi)) sat_q <= 1'b1;
            state_q   <= S_P_M3;
            started_q <= 1'b0;
          end

          S_P_M3: if (mul_done) begin state_q <= S_P_M4; started_q <= 1'b0; end

          S_P_M4: if (mul_done) begin
            r0_i_q <= clip16(32'(r0_i_q) + prod_hi);
            if (ovf16(32'(r0_i_q) + prod_hi)) sat_q <= 1'b1;
            state_q   <= S_P_M5;
            started_q <= 1'b0;
          end

          S_P_M5: if (mul_done) begin state_q <= S_P_M6; started_q <= 1'b0; end

          S_P_M6: if (mul_done) begin
            if (counted) begin
              if (first_q || p_val > peak_pow_q) begin
                peak_bin_q <= m_q;
                peak_pow_q <= p_val;
              end
              first_q <= 1'b0;
              total_q <= total_sum[32] ? 32'hFFFF_FFFF : total_sum[31:0];
              if (total_sum[32]) sat_q <= 1'b1;
              if (in_band) begin
                band_q <= band_sum[32] ? 32'hFFFF_FFFF : band_sum[31:0];
                if (band_sum[32]) sat_q <= 1'b1;
              end
            end
            started_q <= 1'b0;
            if (m_q == 7'd64) begin
              state_q <= S_N_M1;
            end else begin
              m_q     <= m_q + 7'd1;
              state_q <= S_P_RD0;
            end
          end

          // ---------------------------------------------------------------- flags
          S_N_M1: if (mul_done) begin
            band_ok_q <= (band_x256 >= acc_q[39:0]);
            state_q   <= S_N_M2;
            started_q <= 1'b0;
          end

          S_N_M2: if (mul_done) begin
            decay_q      <= prev_valid_q && (td_x256 < acc_q[39:0]);
            state_q      <= S_FIN;
            started_q    <= 1'b0;
          end

          S_FIN: begin
            prev_valid_q <= 1'b1;
            done_o       <= 1'b1;
            state_q      <= S_IDLE;
          end

          S_ERR: begin
            error_o   <= 1'b1;
            state_q   <= S_IDLE;
            started_q <= 1'b0;
            gnt_q     <= 1'b0;
          end

          default: state_q <= S_IDLE;
        endcase
      end
    end
  end

  assign busy_o         = (state_q != S_IDLE);
  assign sat_o          = sat_q;
  assign prev_valid_o   = prev_valid_q;
  assign band_ok_o      = band_ok_q;
  assign decay_o        = decay_q;
  assign peak_bin_o     = peak_bin_q;
  assign peak_pow_o     = peak_pow_q;
  assign band_energy_o  = band_q;
  assign total_energy_o = total_q;
  assign td_energy_o    = td_q;
  assign td_prev_o      = tdp_q;
  assign cycles_o       = cycle_q;

  // observation points for the testbench (removed by synthesis)
  logic        dbg_bin_valid;
  logic [6:0]  dbg_k;
  logic signed [15:0] dbg_xr, dbg_xi;
  logic [31:0] dbg_p;
  assign dbg_bin_valid = (state_q == S_P_M6) && mul_done;
  logic dbg_win_end;                    // the last windowed word has been written
  assign dbg_win_end = (state_q == S_W_WR) && rsp_valid && (m_q == 7'd63);
  assign dbg_k  = m_q;
  assign dbg_xr = r0_r_q;
  assign dbg_xi = r0_i_q;
  assign dbg_p  = p_val;

endmodule
