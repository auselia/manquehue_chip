// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Core-level test: streams the vectors from sim/fft/vectors through fft_hwpe_core and compares
// the load stage, the FFT output, every bin power, the dump stream, and all result registers
// with the Python golden model, bit for bit.

module tb_fft_hwpe_core;

  parameter int NB = 96;                    // number of blocks, set by run.sh
  parameter string VDIR = "vectors";
  parameter bit BACKPRESSURE = 1'b1;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] in_mem   [NB*64];
  logic [31:0] cfg_mem  [NB*4];
  logic [31:0] exp_xw   [NB*128];
  logic [31:0] exp_z    [NB*64];
  logic [31:0] exp_x    [NB*65];
  logic [31:0] exp_p    [NB*65];
  logic [31:0] exp_f    [NB*8];

  initial begin
    $readmemh({VDIR, "/in.hex"},     in_mem);
    $readmemh({VDIR, "/cfg.hex"},    cfg_mem);
    $readmemh({VDIR, "/exp_xw.hex"}, exp_xw);
    $readmemh({VDIR, "/exp_z.hex"},  exp_z);
    $readmemh({VDIR, "/exp_x.hex"},  exp_x);
    $readmemh({VDIR, "/exp_p.hex"},  exp_p);
    $readmemh({VDIR, "/exp_f.hex"},  exp_f);
  end

  // DUT signals
  logic        start, abort, clr_prev;
  logic [3:0]  gain_shift, en_shift;
  logic signed [15:0] dc_offset;
  logic [6:0]  kmin, band_lo, band_hi;
  logic [7:0]  band_thr, decay_thr;
  logic        dump_en;
  logic        sample_valid, sample_ready;
  logic [31:0] sample;
  logic        result_valid, result_ready;
  logic [31:0] result;
  logic        busy, done;
  logic        sat, prev_valid, band_ok, decay;
  logic [6:0]  peak_bin;
  logic [31:0] peak_pow, band_energy, total_energy, td_energy, td_prev, cycles;

  fft_hwpe_core dut (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(start), .abort_i(abort), .clr_prev_i(clr_prev),
    .gain_shift_i(gain_shift), .en_shift_i(en_shift), .dc_offset_i(dc_offset),
    .kmin_i(kmin), .band_lo_i(band_lo), .band_hi_i(band_hi),
    .band_thr_i(band_thr), .decay_thr_i(decay_thr), .dump_en_i(dump_en),
    .sample_valid_i(sample_valid), .sample_ready_o(sample_ready), .sample_i(sample),
    .result_valid_o(result_valid), .result_ready_i(result_ready), .result_o(result),
    .busy_o(busy), .done_o(done),
    .sat_o(sat), .prev_valid_o(prev_valid), .band_ok_o(band_ok), .decay_o(decay),
    .peak_bin_o(peak_bin), .peak_pow_o(peak_pow), .band_energy_o(band_energy),
    .total_energy_o(total_energy), .td_energy_o(td_energy), .td_prev_o(td_prev), .cycles_o(cycles)
  );

  function automatic logic [5:0] bitrev6(input logic [5:0] v);
    for (int i = 0; i < 6; i++) bitrev6[i] = v[5-i];
  endfunction

  int errors = 0;
  int blk;
  int min_cycles = 1 << 30, max_cycles = 0;
  int n_dump = 0;
  int n_pow  = 0;
  logic [15:0] lfsr = 16'hACE1;

  task automatic fail(input string what, input int idx, input logic [31:0] got, input logic [31:0] exp);
    errors++;
    if (errors <= 20)
      $display("MISMATCH block %0d (%s) %s[%0d]: got %08x expected %08x", blk, blk_name(blk), what, idx, got, exp);
  endtask

  // names for the log
  string names [NB];
  initial begin
    int fd, r;
    string line;
    fd = $fopen({VDIR, "/names.txt"}, "r");
    for (int i = 0; i < NB; i++) begin
      r = $fgets(line, fd);
      names[i] = line;
    end
    $fclose(fd);
  end
  function automatic string blk_name(input int b);
    return names[b];
  endfunction

  // random back-pressure on the dump stream
  always_ff @(posedge clk) begin
    lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
  end
  assign result_ready = BACKPRESSURE ? (lfsr[0] | lfsr[5] | lfsr[9]) : 1'b1;

  // monitors
  always_ff @(posedge clk) begin
    if (rst_n && result_valid && result_ready) begin
      if (n_dump < 65) begin
        if (result !== exp_x[blk*65 + n_dump]) fail("dump", n_dump, result, exp_x[blk*65 + n_dump]);
      end else fail("dump-extra", n_dump, result, 0);
      n_dump <= n_dump + 1;
    end
    if (rst_n && dut.feat_valid) begin
      if (dut.i_feat.pw !== exp_p[blk*65 + dut.xk_q]) fail("power", dut.xk_q, dut.i_feat.pw, exp_p[blk*65 + dut.xk_q]);
      n_pow <= n_pow + 1;
    end
  end

  task automatic run_block(input int b);
    logic [31:0] w;
    blk = b;
    n_dump = 0;
    n_pow = 0;
    w = cfg_mem[b*4 + 0];
    gain_shift = w[3:0];
    en_shift   = w[11:8];
    dc_offset  = w[31:16];
    w = cfg_mem[b*4 + 1];
    kmin = w[6:0]; band_lo = w[14:8]; band_hi = w[22:16];
    w = cfg_mem[b*4 + 2];
    band_thr = w[7:0]; decay_thr = w[15:8];
    dump_en = 1'b1;

    if (cfg_mem[b*4 + 3][1]) begin
      @(posedge clk); clr_prev <= 1'b1;
      @(posedge clk); clr_prev <= 1'b0;
    end
    @(posedge clk); start <= 1'b1;
    @(posedge clk); start <= 1'b0;

    // stream the 64 words, one per cycle
    for (int i = 0; i < 64; i++) begin
      sample_valid <= 1'b1;
      sample       <= in_mem[b*64 + i];
      @(posedge clk);
      while (!sample_ready) @(posedge clk);
    end
    sample_valid <= 1'b0;

    // after load: windowed samples in bit-reversed positions
    wait (dut.state_q == dut.S_FFT);
    #1;
    for (int m = 0; m < 64; m++) begin
      logic [31:0] e0, e1;
      e0 = exp_xw[b*128 + 2*m];
      e1 = exp_xw[b*128 + 2*m + 1];
      if (dut.re_mem_q[bitrev6(m[5:0])] !== e0[15:0]) fail("xw.re", m, {16'h0, dut.re_mem_q[bitrev6(m[5:0])]}, e0);
      if (dut.im_mem_q[bitrev6(m[5:0])] !== e1[15:0]) fail("xw.im", m, {16'h0, dut.im_mem_q[bitrev6(m[5:0])]}, e1);
    end

    // after the FFT: Z[k] in natural order
    wait (dut.state_q == dut.S_POST);
    #1;
    for (int k = 0; k < 64; k++) begin
      logic [31:0] e;
      e = exp_z[b*64 + k];
      if ({dut.re_mem_q[k], dut.im_mem_q[k]} !== e) fail("Z", k, {dut.re_mem_q[k], dut.im_mem_q[k]}, e);
    end

    wait (done);
    @(posedge clk); #1;
    if (n_dump != 65) fail("dump-count", n_dump, n_dump, 65);
    if (n_pow  != 65) fail("power-count", n_pow, n_pow, 65);
    begin
      logic [31:0] f [8];
      for (int i = 0; i < 8; i++) f[i] = exp_f[b*8 + i];
      if (peak_bin     !== f[0][6:0]) fail("peak_bin", 0, {25'h0, peak_bin}, f[0]);
      if (peak_pow     !== f[1])      fail("peak_pow", 0, peak_pow, f[1]);
      if (band_energy  !== f[2])      fail("band", 0, band_energy, f[2]);
      if (total_energy !== f[3])      fail("total", 0, total_energy, f[3]);
      if (td_energy    !== f[4])      fail("td", 0, td_energy, f[4]);
      if (td_prev      !== f[5])      fail("td_prev", 0, td_prev, f[5]);
      if (sat          !== f[6][2])   fail("sat", 0, {31'h0, sat}, {31'h0, f[6][2]});
      if (prev_valid   !== f[6][3])   fail("prev_valid", 0, {31'h0, prev_valid}, {31'h0, f[6][3]});
      if (band_ok      !== f[6][4])   fail("band_ok", 0, {31'h0, band_ok}, {31'h0, f[6][4]});
      if (decay        !== f[6][5])   fail("decay", 0, {31'h0, decay}, {31'h0, f[6][5]});
    end
    if (int'(cycles) < min_cycles) min_cycles = int'(cycles);
    if (int'(cycles) > max_cycles) max_cycles = int'(cycles);
    repeat (3) @(posedge clk);
  endtask

  initial begin
    start = 0; abort = 0; clr_prev = 0; sample_valid = 0; sample = 0; dump_en = 1;
    gain_shift = 3; en_shift = 4; dc_offset = 0; kmin = 3; band_lo = 8; band_hi = 20; band_thr = 179; decay_thr = 192;
    blk = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    for (int b = 0; b < NB; b++) run_block(b);
    $display("blocks: %0d  mismatches: %0d  cycles per block (min..max, with dump back-pressure): %0d..%0d",
             NB, errors, min_cycles, max_cycles);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish;
  end

  // watchdog
  initial begin
    #(10 * 1000 * NB * 20);
    $display("TIMEOUT");
    $finish;
  end

endmodule
