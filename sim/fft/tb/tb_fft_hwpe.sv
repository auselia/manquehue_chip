// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Bus-level test of fft_hwpe: a behavioral 2 KB SRAM on the manager port, register accesses on the
// subordinate port, interrupt, dump on and off, random grant delays, and an injected bus error.
// The expected values come from the golden model (sim/fft/vectors).

module tb_fft_hwpe
  import croc_pkg::*;
;

  parameter int NB = 99;
  parameter string VDIR = "vectors";
  parameter int RSP_LAT = 2;            // response latency of the SRAM model, cycles after the grant
  parameter bit RANDOM_GNT = 1'b1;

  localparam logic [31:0] BASE     = 32'h2200_0000;
  localparam logic [31:0] SRAM_BASE = 32'h1000_0000;
  localparam int unsigned SRC_W = 0;     // buffer in the SRAM, in words
  localparam int unsigned DST_W = 128;   // dump region, 65 words

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] in_mem  [NB*64];
  logic [31:0] cfg_mem [NB*4];
  logic [31:0] exp_x   [NB*65];
  logic [31:0] exp_f   [NB*8];
  string names [NB];

  initial begin
    int fd, r;
    string line;
    $readmemh({VDIR, "/in.hex"},    in_mem);
    $readmemh({VDIR, "/cfg.hex"},   cfg_mem);
    $readmemh({VDIR, "/exp_x.hex"}, exp_x);
    $readmemh({VDIR, "/exp_f.hex"}, exp_f);
    fd = $fopen({VDIR, "/names.txt"}, "r");
    for (int i = 0; i < NB; i++) begin
      r = $fgets(line, fd);
      names[i] = line;
    end
    $fclose(fd);
  end

  sbr_obi_req_t sbr_req;
  sbr_obi_rsp_t sbr_rsp;
  mgr_obi_req_t mgr_req;
  mgr_obi_rsp_t mgr_rsp;
  logic irq;

  fft_hwpe dut (
    .clk_i(clk), .rst_ni(rst_n),
    .obi_sbr_req_i(sbr_req), .obi_sbr_rsp_o(sbr_rsp),
    .obi_mgr_req_o(mgr_req), .obi_mgr_rsp_i(mgr_rsp),
    .irq_o(irq)
  );

  // ---------------------------------------------------------------------------
  // SRAM model: 512 words, grant by a random ready, response RSP_LAT cycles after the grant
  // ---------------------------------------------------------------------------
  logic [31:0] sram [512];
  logic [15:0] lfsr = 16'hBEEF;
  logic        rdy_q;
  int          err_word = -1;           // word index that answers with an error
  int          n_access = 0;
  logic        pipe_v    [4];
  logic [31:0] pipe_d    [4];
  logic        pipe_e    [4];

  always_ff @(posedge clk) begin
    lfsr  <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    rdy_q <= RANDOM_GNT ? (lfsr[2] | lfsr[7]) : 1'b1;
  end

  assign mgr_rsp.gnt = rdy_q;

  always_ff @(posedge clk) begin
    for (int i = 3; i > 0; i--) begin
      pipe_v[i] <= pipe_v[i-1];
      pipe_d[i] <= pipe_d[i-1];
      pipe_e[i] <= pipe_e[i-1];
    end
    pipe_v[0] <= 1'b0;
    if (mgr_req.req && rdy_q) begin
      logic [8:0] w;
      w = mgr_req.a.addr[10:2];
      n_access <= n_access + 1;
      pipe_v[0] <= 1'b1;
      pipe_e[0] <= (int'(w) == err_word);
      if (mgr_req.a.we) begin
        sram[w] <= mgr_req.a.wdata;
        pipe_d[0] <= 32'h0;
      end else begin
        pipe_d[0] <= sram[w];
      end
    end
  end

  assign mgr_rsp.rvalid        = pipe_v[RSP_LAT-1];
  assign mgr_rsp.r.rdata       = pipe_d[RSP_LAT-1];
  assign mgr_rsp.r.err         = pipe_e[RSP_LAT-1];
  assign mgr_rsp.r.rid         = '0;
  assign mgr_rsp.r.r_optional  = 1'b0;

  // ---------------------------------------------------------------------------
  // register access
  // ---------------------------------------------------------------------------
  task automatic reg_write(input logic [11:0] off, input logic [31:0] data);
    @(posedge clk);
    sbr_req.req       <= 1'b1;
    sbr_req.a.addr    <= BASE + {20'h0, off};
    sbr_req.a.we      <= 1'b1;
    sbr_req.a.be      <= 4'hF;
    sbr_req.a.wdata   <= data;
    sbr_req.a.aid     <= '0;
    sbr_req.a.a_optional <= 1'b0;
    @(posedge clk);
    sbr_req.req       <= 1'b0;
    sbr_req.a.we      <= 1'b0;
  endtask

  task automatic reg_read(input logic [11:0] off, output logic [31:0] data);
    @(posedge clk);
    sbr_req.req       <= 1'b1;
    sbr_req.a.addr    <= BASE + {20'h0, off};
    sbr_req.a.we      <= 1'b0;
    sbr_req.a.be      <= 4'hF;
    sbr_req.a.wdata   <= '0;
    sbr_req.a.aid     <= '0;
    sbr_req.a.a_optional <= 1'b0;
    @(posedge clk);
    sbr_req.req       <= 1'b0;
    @(negedge clk);
    data = sbr_rsp.r.rdata;
    if (!sbr_rsp.rvalid) $display("ERROR: no rvalid on register read %03x", off);
  endtask

  // ---------------------------------------------------------------------------
  // checks
  // ---------------------------------------------------------------------------
  int errors = 0;
  int blk = 0;
  int min_cycles = 1 << 30, max_cycles = 0;

  task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      errors++;
      if (errors <= 25) $display("MISMATCH block %0d (%s) %s: got %08x expected %08x", blk, names[blk], what, got, exp);
    end
  endtask

  localparam logic [11:0] R_CTRL = 12'h00, R_STATUS = 12'h04, R_SRC = 12'h08, R_DST = 12'h0C, R_IRQ = 12'h10,
                          R_CONFIG = 12'h14, R_SETUP0 = 12'h18, R_SETUP1 = 12'h1C, R_THRESH = 12'h20,
                          R_PEAK = 12'h24, R_PEAKP = 12'h28, R_BAND = 12'h2C, R_TOTAL = 12'h30,
                          R_TD = 12'h34, R_TDP = 12'h38, R_CYC = 12'h3C;

  task automatic wait_done(input int timeout_cycles, output bit timed_out);
    int n = 0;
    timed_out = 0;
    while (!irq && n < timeout_cycles) begin
      @(posedge clk);
      n++;
    end
    if (n >= timeout_cycles) timed_out = 1;
  endtask

  task automatic run_block(input int b, input bit with_dump);
    logic [31:0] r;
    bit to;
    blk = b;
    for (int i = 0; i < 64; i++) sram[SRC_W + i] = in_mem[b*64 + i];
    for (int i = 0; i < 65; i++) sram[DST_W + i] = 32'hDEAD_BEEF;

    reg_write(R_SETUP0, cfg_mem[b*4 + 0]);
    reg_write(R_SETUP1, cfg_mem[b*4 + 1]);
    reg_write(R_THRESH, cfg_mem[b*4 + 2]);
    reg_write(R_SRC, SRAM_BASE + 4 * SRC_W);
    reg_write(R_DST, with_dump ? (SRAM_BASE + 4 * DST_W) : 32'h0);
    reg_write(R_IRQ, 32'h1);
    reg_write(R_STATUS, 32'h0000_0046);      // clear DONE, SAT, ERROR
    reg_write(R_CTRL, {30'h0, cfg_mem[b*4 + 3][1], 1'b1});
    wait_done(2000, to);
    if (to) begin
      errors++;
      $display("TIMEOUT block %0d (%s)", b, names[b]);
      return;
    end
    reg_read(R_STATUS, r);
    expect_eq("STATUS.busy", r[0], 1'b0);
    expect_eq("STATUS.done", r[1], 1'b1);
    expect_eq("STATUS.error", r[6], 1'b0);
    expect_eq("STATUS.sat", r[2], exp_f[b*8 + 6][2]);
    expect_eq("STATUS.prev_valid", r[3], exp_f[b*8 + 6][3]);
    expect_eq("STATUS.band_ok", r[4], exp_f[b*8 + 6][4]);
    expect_eq("STATUS.decay", r[5], exp_f[b*8 + 6][5]);
    reg_read(R_PEAK, r);   expect_eq("PEAK_BIN", r, exp_f[b*8 + 0]);
    reg_read(R_PEAKP, r);  expect_eq("PEAK_POW", r, exp_f[b*8 + 1]);
    reg_read(R_BAND, r);   expect_eq("BAND_ENERGY", r, exp_f[b*8 + 2]);
    reg_read(R_TOTAL, r);  expect_eq("TOTAL_ENERGY", r, exp_f[b*8 + 3]);
    reg_read(R_TD, r);     expect_eq("TD_ENERGY", r, exp_f[b*8 + 4]);
    reg_read(R_TDP, r);    expect_eq("TD_PREV", r, exp_f[b*8 + 5]);
    reg_read(R_CYC, r);
    if (int'(r) < min_cycles) min_cycles = int'(r);
    if (int'(r) > max_cycles) max_cycles = int'(r);
    for (int i = 0; i < 65; i++) begin
      if (with_dump) expect_eq($sformatf("dump[%0d]", i), sram[DST_W + i], exp_x[b*65 + i]);
      else           expect_eq($sformatf("no-dump[%0d]", i), sram[DST_W + i], 32'hDEAD_BEEF);
    end
    // the source buffer must be untouched
    for (int i = 0; i < 64; i++) expect_eq($sformatf("src[%0d]", i), sram[SRC_W + i], in_mem[b*64 + i]);
    reg_write(R_STATUS, 32'h0000_0006);      // clear DONE and SAT
    @(posedge clk);
    @(negedge clk);
    expect_eq("irq cleared", {31'h0, irq}, 32'h0);
  endtask

  initial begin
    logic [31:0] r;
    bit to;
    sbr_req = '0;
    err_word = -1;
    for (int i = 0; i < 4; i++) begin pipe_v[i] = 0; pipe_d[i] = 0; pipe_e[i] = 0; end
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // reset values and CONFIG
    reg_read(R_CONFIG, r); expect_eq("CONFIG", r, 32'h0100_1007);
    reg_read(R_SETUP0, r); expect_eq("SETUP0 reset", r, 32'h0000_0403);
    reg_read(R_SETUP1, r); expect_eq("SETUP1 reset", r, 32'h0014_0803);
    reg_read(R_THRESH, r); expect_eq("THRESH reset", r, 32'h0000_C0B3);
    reg_read(R_STATUS, r); expect_eq("STATUS reset", r, 32'h0);

    for (int b = 0; b < NB; b++) run_block(b, (b % 2) == 0);

    // bus error during the fetch: ERROR set, DONE not set, the engine is usable again afterwards
    err_word = SRC_W + 10;
    blk = 0;
    for (int i = 0; i < 64; i++) sram[SRC_W + i] = in_mem[i];
    reg_write(R_SETUP0, cfg_mem[0]);
    reg_write(R_SETUP1, cfg_mem[1]);
    reg_write(R_THRESH, cfg_mem[2]);
    reg_write(R_SRC, SRAM_BASE + 4 * SRC_W);
    reg_write(R_DST, 32'h0);
    reg_write(R_IRQ, 32'h0);
    reg_write(R_STATUS, 32'h0000_0046);
    reg_write(R_CTRL, 32'h1);
    repeat (400) @(posedge clk);
    reg_read(R_STATUS, r);
    expect_eq("error STATUS.busy", r[0], 1'b0);
    expect_eq("error STATUS.done", r[1], 1'b0);
    expect_eq("error STATUS.error", r[6], 1'b1);
    err_word = -1;
    run_block(1, 1'b1);                      // a good run afterwards

    $display("blocks: %0d  mismatches: %0d  CYCLES register min..max: %0d..%0d  bus accesses: %0d",
             NB, errors, min_cycles, max_cycles, n_access);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish;
  end

  initial begin
    #(10 * 6000 * (NB + 4));
    $display("TIMEOUT (global)");
    $finish;
  end

endmodule
