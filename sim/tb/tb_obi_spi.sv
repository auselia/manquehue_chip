// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Block testbench of obi_spi (docs/spi_adc_spec.md section 7). It drives the OBI subordinate port with byte,
// halfword and word accesses, answers the manager port like an SRAM (with stall and error injection), and puts the
// ADS7057 and SX1276 behavioural models (sim/models) on the pads.
//
// The ADC model input changes at every CS rise: the sample taken at CS fall number k is code_of(k), a bijection of k,
// so every sample found in the SRAM tells which CS fall it was taken at.
// Radio: the SX1276 model speaks SPI mode 0. Modes 1 to 3 are checked at the pins: a monitor decodes MOSI at the
// sampling edges of the mode, and with rf_loop MISO is MOSI, so a master that samples at the wrong edge reads wrong.
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
                          AdcPins = 12'h120, AdcTrig = 12'h124, AdcTpos = 12'h128;
  // radio register byte offsets in the window
  localparam logic [11:0] RfCtrl = 12'h000, RfStatus = 12'h004, RfCmd = 12'h008, RfData = 12'h00C, RfIrqEn = 12'h010,
                          RfIrqSt = 12'h014, RfPins = 12'h018, RfErr = 12'h01C;
  // RF_CTRL fields
  function automatic logic [31:0] rf_ctrl(bit en, bit cpol, bit cpha, int clkdiv, int cs_setup);
    return {12'b0, 4'(cs_setup), 8'(clkdiv), 4'b0, cpha, cpol, 1'b0, en};
  endfunction
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
  logic rf_loop = 1'b0;                              // MISO = MOSI instead of the radio model
  always_comb begin
    pads_in            = PadsInIdle;
    pads_in.adc_sdo    = use_slow ? (adc_sdo_slow === 1'b1) : (adc_sdo === 1'b1);
    pads_in.adc_wake_n = wake_n;
    pads_in.adc_big_n  = big_n;
    pads_in.rf_miso    = rf_loop ? pads_out.rf_mosi : (rf_miso === 1'b1);
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

  // ------------------------------------------------------------------ radio pin monitor
  // SCLK edges while CS is low, MOSI decoded at the sampling edges of the mode under test, CS to SCLK times.
  bit          mon_cpol = 1'b0, mon_cpha = 1'b0;
  int unsigned rf_edges = 0, rf_bits = 0, rf_mosi_at_sample = 0;
  logic [7:0]  rf_shift = '0;
  logic [7:0]  rf_seen [$];
  realtime     t_rf_csn_fall = 0, t_rf_first_edge = 0, t_rf_last_edge = 0, t_rf_csn_rise = 0, t_rf_mosi = 0;
  realtime     t_rf_edge_prev = 0, rf_half_min = 1e9;
  always @(pads_out.rf_mosi) t_rf_mosi = $realtime;
  always @(negedge pads_out.rf_csn) begin
    t_rf_csn_fall = $realtime; rf_edges = 0; rf_bits = 0;
  end
  always @(posedge pads_out.rf_csn) t_rf_csn_rise = $realtime;
  always @(pads_out.rf_sclk) if (!pads_out.rf_csn) begin
    bit leading;
    leading = (pads_out.rf_sclk != mon_cpol);        // the first edge of a bit leaves the idle level
    if (rf_edges == 0) t_rf_first_edge = $realtime;
    if (rf_edges > 0 && $realtime - t_rf_edge_prev < rf_half_min) rf_half_min = $realtime - t_rf_edge_prev;
    t_rf_edge_prev = $realtime;
    t_rf_last_edge = $realtime;
    rf_edges++;
    if (leading == !mon_cpha) begin                  // sampling edge: MOSI must not change here
      if (t_rf_mosi == $realtime) rf_mosi_at_sample++;
      rf_shift = {rf_shift[6:0], pads_out.rf_mosi};
      rf_bits++;
      if (rf_bits % 8 == 0) rf_seen.push_back(rf_shift);
    end
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

  // One SPI transfer through RF_DATA and RF_CMD: the first 8 bytes are pushed before the start, the rest while the
  // transfer runs (the master waits on an empty TX FIFO), the received bytes are popped as they come.
  task automatic rf_xfer(input logic [7:0] tx [], output logic [7:0] rx [], input bit keep_cs);
    int n, pushed, got, guard;
    logic [31:0] st, d;
    n = tx.size();
    rx = new[n];
    pushed = 0; got = 0; guard = 0;
    while (pushed < n && pushed < 8) begin wr(RfData, 4'b0001, 32'(tx[pushed])); pushed++; end
    wr32(RfCmd, 32'(n) | (keep_cs ? 32'h1000 : 32'h0));
    while (got < n && guard < 100000) begin
      rd32(RfStatus, st);
      for (int k = int'(st[15:8]); k < 8 && pushed < n; k++) begin wr(RfData, 4'b0001, 32'(tx[pushed])); pushed++; end
      for (int k = 0; k < int'(st[23:16]) && got < n; k++) begin rd32(RfData, d); rx[got] = d[7:0]; got++; end
      guard++;
    end
    check(got == n, $sformatf("rf_xfer: %0d of %0d bytes received", got, n));
    guard = 0;
    do begin rd32(RfStatus, st); guard++; end while (st[0] && guard < 1000);
    check(!st[0], "rf_xfer: still busy after the last byte");
  endtask

  // register access of the radio model: one read, or a burst write
  task automatic sx_read(input logic [6:0] a, output logic [7:0] v);
    logic [7:0] tx [], rx [];
    tx = new[2]; tx[0] = {1'b0, a}; tx[1] = 8'h00;
    rf_xfer(tx, rx, 1'b0);
    v = rx[1];
  endtask
  task automatic sx_write(input logic [6:0] a, input logic [7:0] data []);
    logic [7:0] tx [], rx [];
    tx = new[data.size() + 1];
    tx[0] = {1'b1, a};
    foreach (data[i]) tx[i + 1] = data[i];
    rf_xfer(tx, rx, 1'b0);
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
    expect32(RfCtrl,   '1, rf_ctrl(0, 0, 0, 24, 1), "RF_CTRL reset (CLKDIV 24, CS_SETUP 1)");
    expect32(RfStatus, '1, 32'h0000_000A, "RF_STATUS reset (TX_EMPTY, RX_EMPTY)");
    expect32(RfIrqSt,  '1, 32'h0000_0002, "RF_IRQ_STATUS reset (TX_EMPTY level)");
    expect32(RfPins,   '1, 32'h0, "RF_PINS reset (RSTN 0, DIO0 low)");
    expect32(RfErr,    '1, 32'h0, "RF_ERR reset");
    for (int off = 'h020; off < 'h100; off += 4) begin
      rd32(12'(off), data);
      check(data == '0, $sformatf("radio block unused word 0x%03h: 0x%08h", off, data));
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

    // ---------------- 9b. triggered capture with POST (the two buffers as one ring, ADC_TPOS) and with START
    expect32(AdcTrig, 32'hFFFF_FFFF, 32'h0, "ADC_TRIG reset value");
    wr32(AdcTrig, 32'h0001_1FFF);
    expect32(AdcTrig, 32'hFFFF_FFFF, 32'h0001_0800, "ADC_TRIG: POST clamped to 2048 samples, bit 0 ignored, START");
    wr32(AdcNsamp, 32'd8);
    begin
      int r, kt, kr, ord_k;
      logic [15:0] ring [], ord [];
      int dmin, dmax;
      dmin = 99; dmax = -99;
      // POST 2, 6, 10 and 14 samples with 8-sample buffers, the trigger at 8 places in the buffer cycle
      for (int post = 2; post <= 14; post += 4) begin
        for (int lead = 0; lead < 8; lead++) begin
          clear_sram();
          wr32(AdcTrig, 32'(post));
          wr32(AdcCtrl, En | Run | Trig | TrigLow | idle_f(3));
          repeat (40 * 21 + lead * 21) @(posedge clk);     // more than two buffers before the trigger
          kt = int'(n_cs_fall);
          wake_n = 1'b0;
          wait_status(StDone, StDone, 2000, $sformatf("POST %0d, lead %0d: DONE", post, lead));
          expect32(AdcCtrl, Run, 32'h0, $sformatf("POST %0d, lead %0d: RUN cleared", post, lead));
          wait_status(StRunning, 32'h0, 100, $sformatf("POST %0d, lead %0d: reader stopped", post, lead));
          expect32(AdcStatus, StFull0 | StFull1, StFull0 | StFull1, $sformatf("POST %0d, lead %0d: both FULL", post, lead));
          rd32(AdcTpos, data);
          check(data[16] == 1'b1 && data[0] == 1'b0 && data[15:12] == '0,
                $sformatf("POST %0d, lead %0d: ADC_TPOS 0x%08h valid and even", post, lead, data));
          r = int'(data[11:0]);
          read_buffer(Buf0, 8, s0);
          read_buffer(Buf1, 8, s1);
          ring = new[16];
          foreach (s0[i]) begin ring[i] = s0[i]; ring[8 + i] = s1[i]; end
          // the ring in time order starts POST samples after TPOS: 16 consecutive samples, the last one stored last
          ord = new[16];
          foreach (ord[i]) ord[i] = ring[(r + post + i) % 16];
          check_run(ord, -1, $sformatf("POST %0d, lead %0d: ring in time order from TPOS + POST", post, lead), ord_k);
          // the sample at TPOS was taken at the trigger, within the word packing and the ADC pipeline
          kr = k_of(ring[r]);
          if (kr - kt < dmin) dmin = kr - kt;
          if (kr - kt > dmax) dmax = kr - kt;
          check(kr >= kt - 3 && kr <= kt - 2,
                $sformatf("POST %0d, lead %0d: sample at TPOS from CS fall %0d, trigger after fall %0d", post, lead, kr, kt));
          wake_n = 1'b1;
          adc_reset();
        end
      end
      $display("  POST: the sample at TPOS is %0d to %0d CS falls from the trigger", dmin, dmax);

      // START: no conversions before the trigger, then 16 samples from the first CS fall after it
      clear_sram();
      wr32(AdcTrig, 32'h0001_0000 | 32'd16);
      wr32(AdcCtrl, En | Run | Trig | TrigLow | idle_f(2));
      repeat (100) @(posedge clk);                        // calibration frame
      kt = int'(n_cs_fall);
      repeat (2000) @(posedge clk);
      check(int'(n_cs_fall) == kt, $sformatf("START: %0d CS falls before the trigger", int'(n_cs_fall) - kt));
      expect32(AdcCount, 32'hFFFF, 32'h0, "START: no sample before the trigger");
      expect32(AdcStatus, StDone | StFull0 | StFull1, 32'h0, "START: no flags before the trigger");
      begin
        realtime tw;
        @(posedge clk);
        wake_n = 1'b0;
        tw = $realtime;
        wait (int'(n_cs_fall) == kt + 1);
        check($realtime - tw < 8 * ClkPeriod, $sformatf("START: first CS fall %0.0f ns after WAKE_N", $realtime - tw));
        $display("  START: first CS fall %0.0f ns after WAKE_N", $realtime - tw);
      end
      wait_status(StDone, StDone, 2000, "START: DONE");
      expect32(AdcStatus, StFull0 | StFull1, StFull0 | StFull1, "START: both buffers FULL");
      expect32(AdcTpos, 32'hFFFF_FFFF, 32'h0001_0000, "START: ADC_TPOS valid, 0");
      read_buffer(Buf0, 8, s0);
      read_buffer(Buf1, 8, s1);
      ring = new[16];
      foreach (s0[i]) begin ring[i] = s0[i]; ring[8 + i] = s1[i]; end
      check_run(ring, kt, "START: buffers 0 and 1 hold the samples from the first CS fall after the trigger", ord_k);
      check_model_timing("START");
      wake_n = 1'b1;
      adc_reset();
      wr32(AdcTrig, 32'h0);
    end

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

    // ---------------- 12. the radio pads did not move during the ADC tests
    check(pads_out.rf_csn == 1'b1 && pads_out.rf_sclk == 1'b0 && pads_out.rf_rstn == 1'b0, "radio pads idle");

    // ---------------- 13. radio: reset pin, RegVersion at CLKDIV 24 and 0, CS timing, SCLK rate
    wr32(RfPins, 32'h1);
    check(pads_out.rf_rstn == 1'b1, "RF_PINS drives RSTN");
    for (int div = 24; div >= 0; div -= 24) begin
      logic [7:0] v;
      wr32(RfCtrl, rf_ctrl(1, 0, 0, div, 1));
      rf_seen.delete();
      sx_read(7'h42, v);
      check(v == 8'h12, $sformatf("RegVersion at CLKDIV %0d: 0x%02h", div, v));
      check(rf_seen.size() == 2 && rf_seen[0] == 8'h42, $sformatf("MOSI at CLKDIV %0d: %0d bytes, first 0x%02h",
            div, rf_seen.size(), rf_seen.size() ? rf_seen[0] : 8'h00));
      check(rf_edges == 32, $sformatf("SCLK edges of a 2-byte transfer: %0d", rf_edges));
      check(rf_half_min >= (div + 1) * ClkPeriod - 0.1, $sformatf("SCLK half period at CLKDIV %0d: %0t", div, rf_half_min));
      check(t_rf_first_edge - t_rf_csn_fall >= ClkPeriod * (div + 1) - 0.1,
            $sformatf("CS fall to the first SCLK edge at CLKDIV %0d: %0t", div, t_rf_first_edge - t_rf_csn_fall));
      check(t_rf_csn_rise - t_rf_last_edge >= ClkPeriod * (div + 1) - 0.1,
            $sformatf("last SCLK edge to CS rise at CLKDIV %0d: %0t", div, t_rf_csn_rise - t_rf_last_edge));
      check(rf_mosi_at_sample == 0, "MOSI changed at a sampling edge");
      rf_half_min = 1e9;
    end
    check(pads_out.rf_sclk == 1'b0 && pads_out.rf_csn == 1'b1, "radio pins idle after the transfers (mode 0)");

    // ---------------- 14. radio: burst write and read back, FIFO writes of 9 and 300 bytes (stall and refill)
    begin
      logic [7:0] frq [], tx [], rx [];
      frq = new[3]; frq[0] = 8'h6C; frq[1] = 8'h80; frq[2] = 8'h00;
      sx_write(7'h06, frq);
      tx = new[4]; tx[0] = 8'h06; tx[1] = 0; tx[2] = 0; tx[3] = 0;
      rf_xfer(tx, rx, 1'b0);
      check(rx[1] == 8'h6C && rx[2] == 8'h80 && rx[3] == 8'h00,
            $sformatf("burst read of 0x06..0x08: %02h %02h %02h", rx[1], rx[2], rx[3]));
      for (int t = 0; t < 2; t++) begin
        int n;
        logic [7:0] pay [], one [];
        n = (t == 0) ? 9 : 255;                       // the radio FIFO pointer wraps at 256
        one = new[1]; one[0] = 8'h80;
        sx_write(7'h0D, one);                         // FifoAddrPtr = FifoTxBase
        pay = new[n];
        foreach (pay[i]) pay[i] = 8'((i * 37 + t * 11 + 5) & 8'hFF);
        sx_write(7'h00, pay);
        begin
          int bad;
          bad = 0;
          for (int i = 0; i < n; i++) if (i_radio.fifo[(8'h80 + i) & 8'hFF] !== pay[i]) bad++;
          check(bad == 0, $sformatf("radio FIFO write of %0d bytes: %0d wrong", n, bad));
        end
      end
      // a 300-byte transfer with the pin decoder (more than the 256-byte radio FIFO, so only the SPI side is checked)
      tx = new[300];
      foreach (tx[i]) tx[i] = 8'((i * 53 + 7) & 8'hFF);
      tx[0] = 8'h80;                                  // FIFO write, the model wraps
      rf_seen.delete();
      rf_xfer(tx, rx, 1'b0);
      begin
        int bad;
        bad = 0;
        foreach (tx[i]) if (i >= rf_seen.size() || rf_seen[i] !== tx[i]) bad++;
        check(bad == 0 && rf_seen.size() == 300, $sformatf("300-byte transfer at the pins: %0d bytes, %0d wrong", rf_seen.size(), bad));
      end
      expect32(RfErr, '1, 32'h0, "no radio error after the refilled transfers");
    end

    // ---------------- 15. radio: payload and TX mode, DIO0 interrupt, DONE interrupt
    begin
      logic [7:0] one [], pay [];
      one = new[1];
      one[0] = 8'h80; sx_write(7'h0D, one);
      pay = new[16];
      foreach (pay[i]) pay[i] = 8'(8'hA0 + i);
      sx_write(7'h00, pay);
      one[0] = 8'd16; sx_write(7'h22, one);           // PayloadLength
      wr32(RfIrqEn, 32'h10);                          // DIO0
      wr32(RfIrqSt, 32'h1F);
      one[0] = 8'h83; sx_write(7'h01, one);           // LoRa TX
      repeat (200) @(posedge clk);                     // TX_DELAY_NS = 2000 in the model
      expect32(RfPins, 32'h100, 32'h100, "DIO0 high after TX");
      expect32(RfIrqSt, 32'h10, 32'h10, "DIO0 rising edge flag");
      check(irq[0] == 1'b1, "radio interrupt on DIO0");
      check(i_radio.last_tx_len == 16, $sformatf("TX payload length %0d", i_radio.last_tx_len));
      begin
        int bad;
        bad = 0;
        for (int i = 0; i < 16; i++) if (i_radio.last_tx[i] !== pay[i]) bad++;
        check(bad == 0, $sformatf("TX payload: %0d bytes wrong", bad));
      end
      wr32(RfIrqSt, 32'h10);
      expect32(RfIrqSt, 32'h10, 32'h0, "DIO0 flag cleared");
      wr32(RfIrqEn, 32'h01);                          // DONE
      wr32(RfIrqSt, 32'h01);
      check(irq[0] == 1'b0, "radio interrupt cleared");
      one[0] = 8'hFF; sx_write(7'h12, one);           // clear IrqFlags in the radio
      expect32(RfIrqSt, 32'h01, 32'h01, "DONE after a transfer");
      check(irq[0] == 1'b1, "radio interrupt on DONE");
      wr32(RfIrqSt, 32'h01);
      wr32(RfIrqEn, 32'h0);
    end

    // ---------------- 16. radio: modes 1 to 3 at the pins with MISO looped back to MOSI
    rf_loop = 1'b1;
    for (int m = 0; m < 4; m++) begin
      logic [7:0] tx [], rx [];
      bit cpol, cpha;
      int bad;
      cpol = m[1]; cpha = m[0];
      wr32(RfCtrl, rf_ctrl(1, cpol, cpha, 2, 2));
      mon_cpol = cpol; mon_cpha = cpha;
      repeat (4) @(posedge clk);
      check(pads_out.rf_sclk == cpol, $sformatf("mode %0d: SCLK idles at %0d", m, pads_out.rf_sclk));
      tx = new[12];
      foreach (tx[i]) tx[i] = 8'((i * 29 + m * 64 + 3) & 8'hFF);
      rf_seen.delete();
      rf_mosi_at_sample = 0;
      rf_xfer(tx, rx, 1'b0);
      bad = 0;
      foreach (tx[i]) if (rx[i] !== tx[i] || i >= rf_seen.size() || rf_seen[i] !== tx[i]) bad++;
      check(bad == 0, $sformatf("mode %0d: %0d of 12 bytes wrong (loopback and pin decoder)", m, bad));
      check(rf_mosi_at_sample == 0, $sformatf("mode %0d: MOSI changed at a sampling edge", m));
      check(pads_out.rf_sclk == cpol && pads_out.rf_csn == 1'b1, $sformatf("mode %0d: pins idle after the transfer", m));
    end
    mon_cpol = 1'b0; mon_cpha = 1'b0;

    // ---------------- 17. radio: KEEP_CS, overflow, underflow, SW_RST during a transfer, EN = 0
    begin
      logic [7:0] tx [], rx [];
      wr32(RfCtrl, rf_ctrl(1, 0, 0, 1, 1));
      tx = new[2]; tx[0] = 8'h11; tx[1] = 8'h22;
      rf_xfer(tx, rx, 1'b1);
      repeat (20) @(posedge clk);
      check(pads_out.rf_csn == 1'b0, "KEEP_CS: CS stays low after the transfer");
      rf_xfer(tx, rx, 1'b0);
      check(pads_out.rf_csn == 1'b1, "CS rises after a transfer without KEEP_CS");
      for (int i = 0; i < 9; i++) wr(RfData, 4'b0100, 32'(i) << 16);   // lane 2, the 9th byte overflows
      expect32(RfStatus, 32'h0000_FF04, 32'h0000_0804, "TX FIFO full with 8 bytes");
      expect32(RfErr, 32'h1, 32'h1, "TX_OVERFLOW");
      expect32(RfIrqSt, 32'h8, 32'h8, "ERROR in RF_IRQ_STATUS");
      rd32(RfData, data);
      expect32(RfErr, 32'h4, 32'h4, "RX_UNDERFLOW on a read of the empty RX FIFO");
      check(data[7:0] == rx[1], $sformatf("underflow returns the last byte 0x%02h, got 0x%02h", rx[1], data[7:0]));
      wr32(RfErr, 32'h7);
      expect32(RfErr, '1, 32'h0, "RF_ERR cleared");
      wr32(RfCtrl, rf_ctrl(1, 0, 0, 24, 1));
      wr32(RfCmd, 32'd100);                           // 8 bytes in the FIFO, 100 to send: waits for more
      repeat (600) @(posedge clk);
      expect32(RfStatus, 32'h1, 32'h1, "busy during the long transfer");
      wr32(RfCtrl, rf_ctrl(1, 0, 0, 24, 1) | 32'h2);  // SW_RST
      repeat (2) @(posedge clk);
      expect32(RfStatus, 32'h0000_FF1F, 32'h0000_000A, "SW_RST: idle, both FIFOs empty");
      check(pads_out.rf_csn == 1'b1 && pads_out.rf_sclk == 1'b0, "SW_RST: pins idle");
      wr32(RfCtrl, rf_ctrl(0, 1, 0, 24, 1));          // EN = 0 with CPOL 1: SCLK idles high
      check(pads_out.rf_csn == 1'b1 && pads_out.rf_sclk == 1'b1 && pads_out.rf_mosi == 1'b0, "EN = 0: pins idle");
      wr32(RfCtrl, rf_ctrl(0, 0, 0, 24, 1));
    end
    rf_loop = 1'b0;

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
