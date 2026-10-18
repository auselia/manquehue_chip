// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Block testbench of obi_spi (docs/spi_adc_spec.md section 7). It drives the OBI subordinate port with byte,
// halfword and word accesses, answers the manager port like an SRAM (with stall and error injection), and puts the
// ADS7057 and SX1276 behavioural models (sim/models) on the pads.
//
// The ADC model input changes at every CS rise: the sample taken at CS fall number k is code_of(k), a bijection of k,
// so every sample found in the SRAM tells which CS fall it was taken at.
// Run: scripts/sim/run_obi_spi_tb.sh

`timescale 1ns/1ps

module tb_obi_spi;
  import croc_pkg::*;
  import obi_spi_pkg::*;

  localparam realtime     ClkPeriod = 55.0;            // ns, 18.18 MHz sign-off clock
  localparam logic [31:0] Base      = user_pkg::UserSpiAddrBase;
  localparam logic [31:0] Buf0      = 32'h1000_0100;
  localparam logic [31:0] Buf1      = 32'h1000_0300;

  // ADC register byte offsets in the window
  localparam logic [11:0] AdcCtrl = 12'h100, AdcStatus = 12'h104, AdcBuf0 = 12'h108, AdcBuf1 = 12'h10C,
                          AdcNsamp = 12'h110, AdcIrqEn = 12'h114, AdcLast = 12'h118, AdcCount = 12'h11C,
                          AdcPins = 12'h120;
  // ADC_CTRL fields
  localparam logic [31:0] En = 32'h1, Run = 32'h2, Trig = 32'h4, SwTrig = 32'h8, Cal = 32'h10, SwRst = 32'h20,
                          SdoNeg = 32'h1000, TrigLow = 32'h4000, Half = 32'h8000;
  function automatic logic [31:0] idle_f(int n); return 32'(n) << 8; endfunction
  // ADC_STATUS fields
  localparam logic [31:0] StRunning = 32'h1, StFull0 = 32'h2, StFull1 = 32'h4, StOverrun = 32'h8, StBusErr = 32'h10,
                          StDone = 32'h20, StWake = 32'h40, StActive = 32'h100;

  logic clk = 1'b0, rst_n = 1'b0;
  always #(ClkPeriod/2) clk = ~clk;

  sbr_obi_req_t  sbr_req;
  sbr_obi_rsp_t  sbr_rsp;
  mgr_obi_req_t  mgr_req;
  mgr_obi_rsp_t  mgr_rsp;
  logic [1:0]    irq;
  spi_pads_out_t pads_out;
  spi_pads_in_t  pads_in;
  logic          testmode = 1'b0;

  obi_spi #(
    .SbrObiCfg ( SbrObiCfg     ),
    .sbr_req_t ( sbr_obi_req_t ),
    .sbr_rsp_t ( sbr_obi_rsp_t ),
    .mgr_req_t ( mgr_obi_req_t ),
    .mgr_rsp_t ( mgr_obi_rsp_t )
  ) i_dut (
    .clk_i         ( clk      ),
    .rst_ni        ( rst_n    ),
    .testmode_i    ( testmode ),
    .obi_sbr_req_i ( sbr_req  ),
    .obi_sbr_rsp_o ( sbr_rsp  ),
    .obi_mgr_req_o ( mgr_req  ),
    .obi_mgr_rsp_i ( mgr_rsp  ),
    .irq_o         ( irq      ),
    .pads_o        ( pads_out ),
    .pads_i        ( pads_in  )
  );

  // ------------------------------------------------------------------ models on the pads
  wire adc_sdo, rf_miso, rf_dio0;
  logic [13:0] ain_code;

  ads7057_model i_adc (
    .cs_n     ( pads_out.adc_csn  ),
    .sclk     ( pads_out.adc_sclk ),
    .sdo      ( adc_sdo           ),
    .ain_code ( ain_code          )
  );

  // the same ADC behind a slow board: SDO 35 ns after the SCLK rising edge, more than half a clock (27.5 ns)
  wire  adc_sdo_slow;
  logic use_slow = 1'b0;
  ads7057_model #(.TCO_NS(35.0)) i_adc_slow (
    .cs_n     ( pads_out.adc_csn  ),
    .sclk     ( pads_out.adc_sclk ),
    .sdo      ( adc_sdo_slow      ),
    .ain_code ( ain_code          )
  );

  sx1276_model i_radio (
    .nss_n ( pads_out.rf_csn  ),
    .sclk  ( pads_out.rf_sclk ),
    .mosi  ( pads_out.rf_mosi ),
    .miso  ( rf_miso          ),
    .dio0  ( rf_dio0          )
  );

  logic wake_n = 1'b1, big_n = 1'b1;
  always_comb begin
    pads_in            = PadsInIdle;
    pads_in.adc_sdo    = use_slow ? (adc_sdo_slow === 1'b1) : (adc_sdo === 1'b1);
    pads_in.adc_wake_n = wake_n;
    pads_in.adc_big_n  = big_n;
    pads_in.rf_miso    = (rf_miso === 1'b1);
    pads_in.rf_dio0    = (rf_dio0 === 1'b1);
  end

  // input of the ADC: code_of(k) is sampled at CS fall number k (k counts from 0)
  function automatic logic [13:0] code_of(int k); return 14'((k * 1237 + 5000) % 16384); endfunction
  function automatic logic [15:0] sext(logic [13:0] c); return {{2{c[13]}}, c}; endfunction
  int unsigned n_cs_fall = 0;
  realtime     t_cs_fall_prev = 0, cs_period = 0;
  realtime     t_cs_fall = 0, cs_low_time = 0;
  initial ain_code = code_of(0);
  always @(negedge pads_out.adc_csn) begin
    n_cs_fall++;
    cs_period      = $realtime - t_cs_fall;
    t_cs_fall      = $realtime;
  end
  always @(posedge pads_out.adc_csn) if (n_cs_fall > 0) begin
    ain_code    = code_of(n_cs_fall);
    cs_low_time = $realtime - t_cs_fall;
  end

  // ------------------------------------------------------------------ manager port: SRAM-like responder
  logic [31:0] sram [logic [31:2]];
  logic        mgr_stall = 1'b0;
  logic [31:0] mgr_err_addr = '1;                  // a write to this address gets an OBI error
  logic        mgr_rvalid_q, mgr_err_q;
  logic [MgrObiCfg.IdWidth-1:0] mgr_rid_q;
  int unsigned mgr_writes = 0;

  always @(posedge clk) begin
    mgr_rvalid_q <= mgr_req.req & ~mgr_stall;
    mgr_rid_q    <= mgr_req.a.aid;
    mgr_err_q    <= mgr_req.req & ~mgr_stall & (mgr_req.a.addr == mgr_err_addr);
    if (mgr_req.req && !mgr_stall && mgr_req.a.we) begin
      sram[mgr_req.a.addr[31:2]] = mgr_req.a.wdata;
      mgr_writes++;
    end
  end
  always_comb begin
    mgr_rsp         = '0;
    mgr_rsp.gnt     = mgr_req.req & ~mgr_stall;
    mgr_rsp.rvalid  = mgr_rvalid_q;
    mgr_rsp.r.rid   = mgr_rid_q;
    mgr_rsp.r.err   = mgr_err_q;
  end

  // OBI rule on the manager port: a request is not taken back before its grant, address and data stay stable
  logic        mgr_wait_q = 1'b0;
  mgr_obi_a_chan_t mgr_a_q;
  always @(posedge clk) begin
    if (rst_n && mgr_wait_q && (!mgr_req.req || mgr_req.a != mgr_a_q))
      check(1'b0, "manager port changed a request before its grant");
    mgr_wait_q <= mgr_req.req & ~mgr_rsp.gnt;
    mgr_a_q    <= mgr_req.a;
  end

  // ------------------------------------------------------------------ checks and bus tasks
  int unsigned errors = 0, checks = 0;

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      $display("[%0t] FAIL: %s", $time, what);
    end
  endtask

  task automatic obi_xfer(input logic [31:0] addr, input bit we, input logic [3:0] be,
                          input logic [31:0] wdata, input logic [SbrObiCfg.IdWidth-1:0] id,
                          output logic [31:0] rdata, output bit err, output logic [SbrObiCfg.IdWidth-1:0] rid);
    @(negedge clk);
    sbr_req.req     = 1'b1;
    sbr_req.a.addr  = addr;
    sbr_req.a.we    = we;
    sbr_req.a.be    = be;
    sbr_req.a.wdata = wdata;
    sbr_req.a.aid   = id;
    do @(posedge clk); while (!sbr_rsp.gnt);
    #1;
    sbr_req = '0;
    while (!sbr_rsp.rvalid) begin
      @(posedge clk);
      #1;
    end
    rdata = sbr_rsp.r.rdata;
    err   = sbr_rsp.r.err;
    rid   = sbr_rsp.r.rid;
  endtask

  task automatic rd32(input logic [11:0] off, output logic [31:0] data);
    logic [SbrObiCfg.IdWidth-1:0] rid;
    bit err;
    obi_xfer(Base + 32'(off), 1'b0, 4'hF, '0, '0, data, err, rid);
    check(!err, $sformatf("read 0x%03h gave an OBI error", off));
  endtask

  task automatic wr(input logic [11:0] off, input logic [3:0] be, input logic [31:0] data);
    logic [31:0] rdata;
    logic [SbrObiCfg.IdWidth-1:0] rid;
    bit err;
    obi_xfer(Base + 32'(off), 1'b1, be, data, '0, rdata, err, rid);
    check(!err, $sformatf("write 0x%03h gave an OBI error", off));
  endtask

  task automatic wr32(input logic [11:0] off, input logic [31:0] data); wr(off, 4'hF, data); endtask

  task automatic expect32(input logic [11:0] off, input logic [31:0] mask, input logic [31:0] exp, input string what);
    logic [31:0] d;
    rd32(off, d);
    check((d & mask) == (exp & mask), $sformatf("%s: 0x%03h = 0x%08h, expected 0x%08h (mask 0x%08h)",
                                              what, off, d, exp, mask));
  endtask

  // wait until (status & mask) == value, at most `limit` clocks
  task automatic wait_status(input logic [31:0] mask, input logic [31:0] value, input int limit, input string what);
    logic [31:0] d;
    int t;
    t = 0;
    do begin
      rd32(AdcStatus, d);
      t++;
    end while ((d & mask) != value && t < limit);
    check((d & mask) == value, $sformatf("%s: ADC_STATUS 0x%08h, waited for 0x%08h (mask 0x%08h)", what, d, value, mask));
  endtask

  // samples of a buffer from the SRAM, in order
  task automatic read_buffer(input logic [31:0] base, input int nsamp, output logic [15:0] s []);
    s = new[nsamp];
    for (int i = 0; i < nsamp / 2; i++) begin
      logic [31:0] w;
      w = sram.exists((base >> 2) + i) ? sram[(base >> 2) + i] : 32'hDEAD_BEEF;
      s[2*i]   = w[15:0];
      s[2*i+1] = w[31:16];
    end
  endtask

  // CS fall at which a sample was taken (-1 when it matches none of the falls so far)
  function automatic int k_of(logic [15:0] smp);
    for (int k = 0; k <= int'(n_cs_fall); k++) if (sext(code_of(k)) == smp) return k;
    return -1;
  endfunction

  // the samples are consecutive CS falls starting at k0 (k0 < 0: any start), returns the first k
  task automatic check_run(input logic [15:0] s [], input int k0, input string what, output int kfirst);
    kfirst = k_of(s[0]);
    check(kfirst >= 0, $sformatf("%s: first sample 0x%04h is no ADC input", what, s[0]));
    if (k0 >= 0) check(kfirst == k0, $sformatf("%s: first sample from CS fall %0d, expected %0d", what, kfirst, k0));
    for (int i = 1; i < s.size(); i++)
      check(s[i] == sext(code_of(kfirst + i)),
            $sformatf("%s: sample %0d = 0x%04h, expected 0x%04h (CS fall %0d)", what, i, s[i],
                      sext(code_of(kfirst + i)), kfirst + i));
  endtask

  task automatic clear_sram; sram.delete(); endtask

  // stop the reader the way firmware does: RUN = 0, wait for the end of the frame, then EN = 0 and clear the flags
  task automatic adc_reset;
    logic [31:0] ctrl;
    rd32(AdcCtrl, ctrl);
    wr32(AdcCtrl, ctrl & ~(Run | Trig));
    wait_status(StRunning, 32'h0, 200, "reader stops after RUN = 0");
    repeat (8) @(posedge clk);                    // staging FIFO drains
    wr32(AdcCtrl, TrigLow | idle_f(3));
    wr32(AdcStatus, 32'hFF);
    repeat (4) @(posedge clk);
  endtask

  // model timing checks must stay at zero
  task automatic check_model_timing(input string what);
    check(i_adc.tacq_violations == 0 && i_adc.tsu_violations == 0 && i_adc.tht_violations == 0 &&
          i_adc.tph_violations == 0, $sformatf("%s: ADS7057 timing violations tacq %0d tsu %0d tht %0d tph %0d",
          what, i_adc.tacq_violations, i_adc.tsu_violations, i_adc.tht_violations, i_adc.tph_violations));
    check(i_adc.duty_violations == 0, $sformatf("%s: SCLK duty violations %0d", what, i_adc.duty_violations));
    check(i_adc.short_frame_count == 0, $sformatf("%s: short frames %0d", what, i_adc.short_frame_count));
  endtask

  // ------------------------------------------------------------------ test sequence
  localparam logic [3:0]  Bes      [7] = '{4'b0001, 4'b0010, 4'b0100, 4'b1000, 4'b0011, 4'b1100, 4'b1111};
  localparam logic [11:0] Unmapped [4] = '{12'h200, 12'h204, 12'h7FC, 12'hFFC};

  initial begin : main
    logic [31:0] data;
    logic [SbrObiCfg.IdWidth-1:0] rid;
    logic [15:0] s0 [], s1 [];
    int k0, k1;
    bit err;
    sbr_req = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // ---------------- 1. bus front end and reset values
    check(pads_out == PadsOutIdle, $sformatf("pads after reset %b, expected %b", pads_out, PadsOutIdle));
    check(irq == '0, "interrupts after reset");
    for (int off = 0; off < 'h100; off += 4) begin
      rd32(12'(off), data);
      check(data == '0, $sformatf("radio block read 0x%03h: 0x%08h", off, data));
    end
    expect32(AdcCtrl,   '1, TrigLow | idle_f(3), "ADC_CTRL reset");
    expect32(AdcStatus, '1, 32'h0, "ADC_STATUS reset");
    expect32(AdcNsamp,  '1, 32'd128, "ADC_NSAMP reset");
    expect32(AdcPins,   '1, 32'h302, "ADC_PINS reset (CAP_EN 1, WAKE_N 1, BIG_N 1)");
    for (int off = 'h124; off < 'h200; off += 4) begin
      rd32(12'(off), data);
      check(data == '0, $sformatf("ADC block unused word 0x%03h: 0x%08h", off, data));
    end
    foreach (Bes[i]) begin
      wr(12'h000, Bes[i], 32'hA5A5_5A5A);
      wr(AdcIrqEn, Bes[i], 32'h0);
    end
    for (int id = 0; id < 2**SbrObiCfg.IdWidth; id++) begin
      obi_xfer(Base + 32'(AdcNsamp), 1'b0, 4'hF, '0, SbrObiCfg.IdWidth'(id), data, err, rid);
      check(rid == SbrObiCfg.IdWidth'(id), $sformatf("rid %0d for aid %0d", rid, id));
    end
    foreach (Unmapped[i]) begin
      obi_xfer(Base + 32'(Unmapped[i]), 1'b0, 4'hF, '0, '0, data, err, rid);
      check(err, $sformatf("read of unmapped 0x%03h gives no error", Unmapped[i]));
      obi_xfer(Base + 32'(Unmapped[i]), 1'b1, 4'hF, '1, '0, data, err, rid);
      check(err, $sformatf("write of unmapped 0x%03h gives no error", Unmapped[i]));
    end

    // ---------------- 2. byte and halfword access, clamping
    wr(AdcBuf0, 4'b0001, 32'h0000_00FF);                // byte 0 only, low 2 bits forced 0
    wr(AdcBuf0, 4'b1100, 32'h1234_0000);                // upper halfword
    expect32(AdcBuf0, '1, 32'h1234_00FC, "ADC_BUF0 byte and halfword writes");
    wr(AdcNsamp, 4'b0011, 32'd7);   expect32(AdcNsamp, '1, 32'd6,    "ADC_NSAMP odd rounds down");
    wr(AdcNsamp, 4'b0011, 32'd1);   expect32(AdcNsamp, '1, 32'd2,    "ADC_NSAMP clamps to 2");
    wr(AdcNsamp, 4'b0011, 32'd2000); expect32(AdcNsamp, '1, 32'd1024, "ADC_NSAMP clamps to 1024");
    wr32(AdcNsamp, 32'd256);
    wr(AdcNsamp, 4'b0001, 32'h0000_0008); expect32(AdcNsamp, '1, 32'd264, "ADC_NSAMP byte write");
    wr(AdcCtrl, 4'b0010, idle_f(1) | TrigLow); expect32(AdcCtrl, 32'hF00, idle_f(2), "ADC_CTRL IDLE clamps to 2");
    wr32(AdcCtrl, TrigLow | idle_f(3));
    wr(AdcPins, 4'b0001, 32'h3);
    check(pads_out.adc_wake_clr == 1'b1 && pads_out.adc_cap_en == 1'b1, "ADC_PINS outputs");
    wr32(AdcPins, 32'h0);
    check(pads_out.adc_wake_clr == 1'b0 && pads_out.adc_cap_en == 1'b0, "ADC_PINS outputs cleared");
    wake_n = 1'b0; big_n = 1'b0;
    repeat (4) @(posedge clk);
    expect32(AdcPins, 32'h300, 32'h000, "ADC_PINS inputs low");
    wake_n = 1'b1; big_n = 1'b1;
    wr32(AdcPins, 32'h2);
    wr32(AdcStatus, 32'hFF);                            // WAKE flag from the test above
    check(pads_out == PadsOutIdle, "pads idle while EN = 0");

    // ---------------- 3. data path: EN and RUN together, 8-sample buffers, IDLE 3
    wr32(AdcBuf0, Buf0);
    wr32(AdcBuf1, Buf1);
    wr32(AdcNsamp, 32'd8);
    wr32(AdcIrqEn, 32'h1);                              // BUF_FULL
    n_cs_fall = 0;
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    wait_status(StFull0, StFull0, 2000, "buffer 0 full");
    check(irq[1] == 1'b1, "ADC interrupt on BUF0_FULL");
    check(i_adc.cal_done == 1'b1, "calibration frame of 24 clocks at enable");
    read_buffer(Buf0, 8, s0);
    check_run(s0, 1, "buffer 0", k0);                   // CS fall 0 is the calibration frame, its successor is discarded
    wait_status(StFull1, StFull1, 2000, "buffer 1 full");
    read_buffer(Buf1, 8, s1);
    check_run(s1, k0 + 8, "buffer 1 continues buffer 0", k1);
    check(cs_period >= 21 * ClkPeriod - 1 && cs_period <= 21 * ClkPeriod + 1,
          $sformatf("frame period at IDLE 3: %0t, expected 21 clocks", cs_period));
    rd32(AdcLast, data);
    k1 = k_of(data[15:0]);
    check(k1 >= int'(n_cs_fall) - 4 && k1 >= 0 && data[31:16] == {16{data[15]}},
          $sformatf("ADC_LAST 0x%08h is the sample of CS fall %0d, %0d falls so far", data, k1, n_cs_fall));
    rd32(AdcCount, data);
    check(data >= 16, $sformatf("ADC_COUNT %0d after two buffers", data));

    // ---------------- 4. overrun of a full buffer, then recovery
    wait_status(StOverrun, StOverrun, 2000, "OVERRUN when buffer 0 is still full");
    read_buffer(Buf0, 8, s0);
    check_run(s0, 1, "buffer 0 kept its data on OVERRUN", k0);
    wr32(AdcStatus, StFull0 | StOverrun);               // release buffer 0
    wait_status(StFull0, StFull0, 4000, "buffer 0 full again");
    read_buffer(Buf0, 8, s0);
    check_run(s0, -1, "buffer 0 after OVERRUN", k0);
    check(k0 > 17, "buffer 0 has new samples");
    check_model_timing("free running, IDLE 3");
    adc_reset();

    // ---------------- 5. frame rate at IDLE 2 and 4, SDO_NEG, SCLK_HALF
    for (int idle = 2; idle <= 4; idle += 2) begin
      clear_sram();
      wr32(AdcCtrl, En | Run | TrigLow | idle_f(idle));
      wait_status(StFull0, StFull0, 2000, $sformatf("buffer 0 full at IDLE %0d", idle));
      check(cs_period >= (18 + idle) * ClkPeriod - 1 && cs_period <= (18 + idle) * ClkPeriod + 1,
            $sformatf("frame period at IDLE %0d: %0t, expected %0d clocks", idle, cs_period, 18 + idle));
      check(cs_low_time >= 18 * ClkPeriod && cs_low_time <= 19 * ClkPeriod + 1,
            $sformatf("CS low time %0t at IDLE %0d", cs_low_time, idle));
      read_buffer(Buf0, 8, s0);
      check_run(s0, -1, $sformatf("IDLE %0d", idle), k0);
      check_model_timing($sformatf("IDLE %0d", idle));
      adc_reset();
    end
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | SdoNeg | idle_f(3));
    wait_status(StFull0, StFull0, 2000, "buffer 0 full with SDO_NEG");
    read_buffer(Buf0, 8, s0);
    check_run(s0, -1, "SDO_NEG", k0);
    check_model_timing("SDO_NEG");
    adc_reset();
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | Half | idle_f(3));
    wait_status(StFull0, StFull0, 4000, "buffer 0 full with SCLK_HALF");
    check(cs_period >= 42 * ClkPeriod - 1 && cs_period <= 42 * ClkPeriod + 1,
          $sformatf("frame period with SCLK_HALF: %0t, expected 42 clocks", cs_period));
    read_buffer(Buf0, 8, s0);
    check_run(s0, -1, "SCLK_HALF", k0);
    check_model_timing("SCLK_HALF");
    adc_reset();

    // slow board: without SDO_NEG the samples are wrong, with SDO_NEG they are right
    use_slow = 1'b1;
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    wait_status(StFull0, StFull0, 2000, "buffer 0 full, slow board without SDO_NEG");
    read_buffer(Buf0, 8, s0);
    begin
      int good;
      good = 0;
      for (int i = 0; i < 8; i++) if (k_of(s0[i]) >= 0) good++;
      check(good < 8, $sformatf("slow board without SDO_NEG: %0d of 8 samples right, expected wrong ones", good));
    end
    adc_reset();
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | SdoNeg | idle_f(3));
    wait_status(StFull0, StFull0, 2000, "buffer 0 full, slow board with SDO_NEG");
    read_buffer(Buf0, 8, s0);
    check_run(s0, -1, "slow board with SDO_NEG", k0);
    adc_reset();
    use_slow = 1'b0;

    // ---------------- 6. recalibration frame during the run
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    wait_status(StFull0, StFull0, 2000, "buffer 0 full before CAL");
    wr32(AdcStatus, StFull0);
    wr32(AdcCtrl, En | Run | TrigLow | Cal | idle_f(3));
    wait_status(StFull1, StFull1, 4000, "buffer 1 full after CAL");
    check(i_adc.recal_count == 1, $sformatf("recalibration frames: %0d", i_adc.recal_count));
    read_buffer(Buf1, 8, s1);
    check_run(s1, -1, "samples around the 64-clock frame are consecutive", k1);
    check_model_timing("recalibration");
    adc_reset();

    // ---------------- 7. manager stall of 200 clocks
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(2));
    @(posedge pads_out.adc_csn);
    mgr_stall = 1'b1;
    repeat (200) @(posedge clk);
    mgr_stall = 1'b0;
    wait_status(StOverrun, StOverrun, 100, "OVERRUN after a 200-clock manager stall");
    adc_reset();
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(2));      // a stall of 60 clocks loses nothing
    @(posedge pads_out.adc_csn);
    mgr_stall = 1'b1;
    repeat (60) @(posedge clk);
    mgr_stall = 1'b0;
    wait_status(StFull0, StFull0, 2000, "buffer 0 full after a 60-clock stall");
    expect32(AdcStatus, StOverrun, 32'h0, "no OVERRUN after a 60-clock stall");
    read_buffer(Buf0, 8, s0);
    check_run(s0, -1, "buffer 0 after a 60-clock stall", k0);
    adc_reset();

    // ---------------- 8. bus error
    clear_sram();
    mgr_err_addr = Buf0 + 32'h4;
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    wait_status(StBusErr, StBusErr, 2000, "BUS_ERROR on an OBI error response");
    mgr_err_addr = '1;
    adc_reset();

    // ---------------- 9. triggered capture (WAKE_N, active low) and SW_TRIG
    clear_sram();
    wr32(AdcIrqEn, 32'h4);                              // DONE
    wr32(AdcCtrl, En | Run | Trig | TrigLow | idle_f(3));
    repeat (40 * 21) @(posedge clk);                    // more than two buffers before the trigger
    expect32(AdcStatus, StFull0 | StFull1 | StDone, 32'h0, "no flags before the trigger");
    wake_n = 1'b0;
    wait_status(StDone, StDone, 2000, "DONE after WAKE_N");
    check(irq[1] == 1'b1, "ADC interrupt on DONE");
    expect32(AdcCtrl, Run, 32'h0, "RUN cleared after the capture");
    wait_status(StRunning, 32'h0, 100, "reader stopped after the capture");
    expect32(AdcStatus, StFull0 | StFull1 | StWake, StFull0 | StFull1 | StWake, "both buffers FULL and WAKE");
    rd32(AdcStatus, data);
    begin
      logic tb;
      tb = data[8];                                     // ACTIVE_BUF points after the trigger buffer
      read_buffer(tb ? Buf1 : Buf0, 8, s0);             // pre-trigger buffer
      read_buffer(tb ? Buf0 : Buf1, 8, s1);             // trigger buffer
      check_run(s0, -1, "pre-trigger buffer", k0);
      check_run(s1, k0 + 8, "trigger buffer follows the pre-trigger buffer", k1);
    end
    wake_n = 1'b1;
    adc_reset();
    clear_sram();
    wr32(AdcCtrl, En | Run | Trig | TrigLow | idle_f(3));
    repeat (40 * 21) @(posedge clk);
    wr32(AdcCtrl, En | Run | Trig | TrigLow | SwTrig | idle_f(3));
    wait_status(StDone, StDone, 2000, "DONE after SW_TRIG");
    adc_reset();

    // ---------------- 10. SW_RST during a capture, then a clean restart
    clear_sram();
    wr32(AdcIrqEn, 32'h0);
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    repeat (100) @(posedge clk);
    wr32(AdcCtrl, En | SwRst | TrigLow | idle_f(3));
    repeat (2) @(posedge clk);
    expect32(AdcCtrl, Run, 32'h0, "RUN cleared by SW_RST");
    expect32(AdcStatus, 32'hFE, 32'h0, "flags cleared by SW_RST");
    clear_sram();
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    wait_status(StFull0, StFull0, 3000, "buffer 0 full after SW_RST");
    read_buffer(Buf0, 8, s0);
    check_run(s0, -1, "after SW_RST", k0);
    adc_reset();

    // ---------------- 11. EN = 0 quiets the pads at once, test mode holds SCLK high
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    repeat (30) @(posedge clk);
    wr32(AdcCtrl, TrigLow | idle_f(3));
    repeat (2) @(posedge clk);                          // the clock gate may still pass the pulse it latched
    #1;
    check(pads_out.adc_csn == 1'b1 && pads_out.adc_sclk == 1'b1,
          $sformatf("ADC pads idle 2 clocks after EN = 0: CSN %b SCLK %b", pads_out.adc_csn, pads_out.adc_sclk));
    testmode = 1'b1;
    wr32(AdcCtrl, En | Run | TrigLow | idle_f(3));
    begin
      int sclk_low;
      sclk_low = 0;
      repeat (200) begin
        @(negedge clk);
        if (pads_out.adc_sclk == 1'b0) sclk_low++;
      end
      check(sclk_low == 0, $sformatf("SCLK low %0d times in test mode", sclk_low));
    end
    testmode = 1'b0;
    adc_reset();

    // ---------------- 12. the radio pads did not move
    check(pads_out.rf_csn == 1'b1 && pads_out.rf_sclk == 1'b0 && pads_out.rf_rstn == 1'b0, "radio pads idle");

    repeat (4) @(posedge clk);
    if (errors == 0) $display("PASS: tb_obi_spi, %0d checks, 0 failures", checks);
    else             $display("FAIL: tb_obi_spi, %0d checks, %0d failures", checks, errors);
    $finish;
  end

  initial begin : timeout
    #(ClkPeriod * 3_000_000);
    $display("FAIL: tb_obi_spi timeout");
    $finish;
  end

endmodule
