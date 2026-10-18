// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Block testbench of obi_spi (docs/spi_adc_spec.md section 7). It drives the OBI subordinate port with byte,
// halfword and word accesses, answers the manager port like an SRAM, and puts the ADS7057 and SX1276
// behavioural models (sim/models) on the pads.
// Skeleton tests: pads at their idle levels, registers read 0, writes are accepted at every width, the
// transaction id comes back, unmapped offsets get an OBI error, the manager port makes no request.
// Run: scripts/sim/run_obi_spi_tb.sh

`timescale 1ns/1ps

module tb_obi_spi;
  import croc_pkg::*;
  import obi_spi_pkg::*;

  localparam time         ClkPeriod = 55ns;            // 18.18 MHz sign-off clock
  localparam logic [31:0] Base      = user_pkg::UserSpiAddrBase;

  logic clk = 1'b0, rst_n = 1'b0;
  always #(ClkPeriod/2) clk = ~clk;

  sbr_obi_req_t  sbr_req;
  sbr_obi_rsp_t  sbr_rsp;
  mgr_obi_req_t  mgr_req;
  mgr_obi_rsp_t  mgr_rsp;
  logic [1:0]    irq;
  spi_pads_out_t pads_out;
  spi_pads_in_t  pads_in;

  obi_spi #(
    .SbrObiCfg ( SbrObiCfg     ),
    .sbr_req_t ( sbr_obi_req_t ),
    .sbr_rsp_t ( sbr_obi_rsp_t ),
    .MgrObiCfg ( MgrObiCfg     ),
    .mgr_req_t ( mgr_obi_req_t ),
    .mgr_rsp_t ( mgr_obi_rsp_t )
  ) i_dut (
    .clk_i         ( clk      ),
    .rst_ni        ( rst_n    ),
    .testmode_i    ( 1'b0     ),
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
  logic [13:0] ain_code = 14'h0123;

  ads7057_model i_adc (
    .cs_n     ( pads_out.adc_csn  ),
    .sclk     ( pads_out.adc_sclk ),
    .sdo      ( adc_sdo           ),
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
    pads_in.adc_sdo    = adc_sdo;
    pads_in.adc_wake_n = wake_n;
    pads_in.adc_big_n  = big_n;
    pads_in.rf_miso    = rf_miso;
    pads_in.rf_dio0    = rf_dio0;
  end

  // ------------------------------------------------------------------ manager port: SRAM-like responder
  // Grants every request and answers one cycle later. Written words are kept for the ADC tests.
  logic [31:0] sram [logic [31:0]];
  logic        mgr_rvalid_q;
  logic [31:0] mgr_rdata_q;
  logic [MgrObiCfg.IdWidth-1:0] mgr_rid_q;
  int unsigned mgr_reqs = 0;

  always @(posedge clk) begin
    mgr_rvalid_q <= mgr_req.req;
    mgr_rid_q    <= mgr_req.a.aid;
    mgr_rdata_q  <= '0;
    if (mgr_req.req) begin
      mgr_reqs++;
      if (mgr_req.a.we) sram[mgr_req.a.addr] = mgr_req.a.wdata;
      else              mgr_rdata_q         <= sram.exists(mgr_req.a.addr) ? sram[mgr_req.a.addr] : '0;
    end
  end
  always_comb begin
    mgr_rsp         = '0;
    mgr_rsp.gnt     = mgr_req.req;
    mgr_rsp.rvalid  = mgr_rvalid_q;
    mgr_rsp.r.rid   = mgr_rid_q;
    mgr_rsp.r.rdata = mgr_rdata_q;
  end

  // ------------------------------------------------------------------ checks
  int unsigned errors = 0, checks = 0;

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      $display("[%0t] FAIL: %s", $time, what);
    end
  endtask

  // One OBI transaction on the subordinate port. Request on the falling edge, granted on a rising edge,
  // response on a following rising edge.
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

  task automatic rd32(input logic [11:0] off, output logic [31:0] data, output bit err);
    logic [SbrObiCfg.IdWidth-1:0] rid;
    obi_xfer(Base + 32'(off), 1'b0, 4'hF, '0, '0, data, err, rid);
  endtask

  task automatic wr(input logic [11:0] off, input logic [3:0] be, input logic [31:0] data, output bit err);
    logic [31:0] rdata;
    logic [SbrObiCfg.IdWidth-1:0] rid;
    obi_xfer(Base + 32'(off), 1'b1, be, data, '0, rdata, err, rid);
  endtask

  // The manager port must stay silent while the ADC reader is not in
  always @(posedge clk) if (rst_n && mgr_req.req)
    check(1'b0, $sformatf("manager port request to 0x%08h", mgr_req.a.addr));

  // ------------------------------------------------------------------ test sequence
  localparam logic [3:0]  Bes      [7] = '{4'b0001, 4'b0010, 4'b0100, 4'b1000, 4'b0011, 4'b1100, 4'b1111};
  localparam logic [11:0] Unmapped [4] = '{12'h200, 12'h204, 12'h7FC, 12'hFFC};

  initial begin : main
    logic [31:0] data;
    logic [SbrObiCfg.IdWidth-1:0] rid;
    bit err;
    sbr_req = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // 1. reset state of the pads and the interrupts
    check(pads_out == PadsOutIdle, $sformatf("pads after reset %b, expected %b", pads_out, PadsOutIdle));
    check(irq == '0, "interrupts after reset");

    // 2. every mapped word reads 0 without error (radio and ADC sub-blocks)
    for (int off = 0; off < 'h200; off += 4) begin
      rd32(12'(off), data, err);
      check(!err && data == '0, $sformatf("read 0x%03h: data 0x%08h err %0b", off, data, err));
    end

    // 3. writes of every width are accepted
    foreach (Bes[i]) begin
      wr(12'h000, Bes[i], 32'hA5A5_5A5A, err);
      check(!err, $sformatf("write be %b to 0x000", Bes[i]));
      wr(12'h100, Bes[i], 32'h1234_5678, err);
      check(!err, $sformatf("write be %b to 0x100", Bes[i]));
    end

    // 4. the transaction id comes back
    for (int id = 0; id < 2**SbrObiCfg.IdWidth; id++) begin
      obi_xfer(Base + 32'h104, 1'b0, 4'hF, '0, SbrObiCfg.IdWidth'(id), data, err, rid);
      check(rid == SbrObiCfg.IdWidth'(id), $sformatf("rid %0d for aid %0d", rid, id));
    end

    // 5. unmapped offsets get an OBI error, writes there too
    foreach (Unmapped[i]) begin
      rd32(Unmapped[i], data, err);
      check(err, $sformatf("read of unmapped 0x%03h gives no error", Unmapped[i]));
      wr(Unmapped[i], 4'hF, 32'hFFFF_FFFF, err);
      check(err, $sformatf("write of unmapped 0x%03h gives no error", Unmapped[i]));
    end

    // 6. the pads did not move during the bus traffic
    check(pads_out == PadsOutIdle, "pads after bus traffic");
    check(mgr_reqs == 0, "manager port requests");

    repeat (4) @(posedge clk);
    if (errors == 0) $display("PASS: tb_obi_spi, %0d checks, 0 failures", checks);
    else             $display("FAIL: tb_obi_spi, %0d checks, %0d failures", checks, errors);
    $finish;
  end

  initial begin : timeout
    #(ClkPeriod * 200_000);
    $display("FAIL: tb_obi_spi timeout");
    $finish;
  end

endmodule
