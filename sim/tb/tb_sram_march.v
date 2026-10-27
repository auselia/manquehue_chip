// March C- of the 2 KB SRAM through the JTAG debug module (system bus access), no CPU involved, on the gate-level macro.
// 512 words of 32 bit, four 512 x 8 SRAM macros side by side (one per byte lane). A word-wide March with solid
// backgrounds finds stuck-at, transition, address-decoder and inter-word coupling faults between bytes lanes and words.
// Faults can be injected into the behavioural SRAM model of byte lane 0 to see what the test reports:
//   +fault=saf0 | saf1 (cell fa, bit fb stuck), cfin (a write to word fa inverts bit fb of word fa2),
//   af (a write to word fa also writes word fa2)      +fa=<word> +fb=<bit> +fa2=<word>
// Result line: "MARCH PASS" or "MARCH FAIL"; every mismatch is listed with element, word, expected and read value.
`timescale 1ns/1ps
module tb_sram_march;
  parameter [31:0] IDCODE = 32'h1C0C_5DB3;
  parameter NW = 512;
  localparam [31:0] BASE = 32'h1000_0000;

  reg clk = 0, rst_n = 0, ref_clk = 0, tck = 0, tms = 1, tdi = 0, trst_n = 0;
  supply1 VDD;
  supply0 VSS;
  wire tdo, uart_tx, status, scan_so;

  croc_soc dut (
    .VDD(VDD), .VSS(VSS),
    .clk_i(clk), .rst_ni(rst_n), .ref_clk_i(ref_clk), .testmode_i(1'b0), .status_o(status),
    .jtag_tck_i(tck), .jtag_tdi_i(tdi), .jtag_tdo_o(tdo), .jtag_tms_i(tms), .jtag_trst_ni(trst_n),
    .uart_rx_i(1'b1), .uart_tx_o(uart_tx),
    .qspi_clk_o(), .qspi_sd_o(), .qspi_sd_i(4'b0000), .qspi_sd_en_o(), .qspi_csn_o(),
    .spi_sck_o(), .spi_sd_o(), .spi_sd_i(1'b0), .spi_cs0_o(), .spi_cs1_o(), .afe_irq_i(1'b1),
    .rf_dio0_i(1'b0), .rf_rstn_o(),
    .gpio_i(2'b00), .gpio_o(), .gpio_out_en_o(),
    .scan_si_i(1'b0), .scan_se_i(1'b0), .scan_so_o(scan_so)
  );
  always #25 clk = ~clk;
  always #15259 ref_clk = ~ref_clk;

  // ---------------- JTAG ----------------
  task jclk(input m, input d);
    begin tms = m; tdi = d; #25 tck = 1; #25 tck = 0; end
  endtask
  task tap_reset; integer i; begin for (i = 0; i < 6; i = i + 1) jclk(1, 0); jclk(0, 0); end endtask
  task shift_ir(input [4:0] ir); integer i;
    begin
      jclk(1, 0); jclk(1, 0); jclk(0, 0); jclk(0, 0);
      for (i = 0; i < 5; i = i + 1) jclk(i == 4, ir[i]);
      jclk(1, 0); jclk(0, 0);
    end
  endtask
  task shift_dr(input integer n, input [63:0] dout, output [63:0] din); integer i;
    begin
      jclk(1, 0); jclk(0, 0); jclk(0, 0);
      din = 64'd0;
      for (i = 0; i < n; i = i + 1) begin
        #5 din[i] = tdo;
        jclk(i == n - 1, dout[i]);
      end
      jclk(1, 0); jclk(0, 0);
    end
  endtask
  reg [63:0] scan_in;
  integer dmi_err = 0;
  task dmi_wr(input [6:0] a, input [31:0] d);
    begin
      shift_dr(41, {23'd0, a, d, 2'd2}, scan_in);
      repeat (40) jclk(0, 0);
    end
  endtask
  task dmi_rd(input [6:0] a, output [31:0] d);
    begin
      shift_dr(41, {23'd0, a, 32'd0, 2'd1}, scan_in);
      repeat (40) jclk(0, 0);
      shift_dr(41, 64'd0, scan_in);
      d = scan_in[33:2];
      if (scan_in[1:0] != 2'd0) dmi_err = dmi_err + 1;
    end
  endtask

  // ---------------- March C- ----------------
  // sbcs: sbreadonaddr, 32-bit access, no autoincrement. A write to sbaddress0 starts a read, a write to sbdata0 a write.
  integer errors = 0, ops = 0, el, i;
  reg [31:0] r, B0, B1;
  task rd(input integer w, input [31:0] exp, input integer element);
    begin
      dmi_wr(7'h39, BASE + 4 * w);
      dmi_rd(7'h3C, r);
      ops = ops + 1;
      if (r !== exp) begin
        errors = errors + 1;
        if (errors <= 40) $display("%0t  MISMATCH element %0d word %0d (0x%08h): expected 0x%08h read 0x%08h  diff 0x%08h",
                                   $time, element, w, BASE + 4 * w, exp, r, r ^ exp);
      end
    end
  endtask
  task wr(input integer w, input [31:0] d);
    begin
      dmi_wr(7'h39, BASE + 4 * w);
      dmi_wr(7'h3C, d);
      ops = ops + 1;
    end
  endtask
  // r then w at the same word: the address write starts the read, the data write stores
  task rw(input integer w, input [31:0] exp, input [31:0] d, input integer element);
    begin
      dmi_wr(7'h39, BASE + 4 * w);
      dmi_rd(7'h3C, r);
      ops = ops + 1;
      if (r !== exp) begin
        errors = errors + 1;
        if (errors <= 40) $display("%0t  MISMATCH element %0d word %0d (0x%08h): expected 0x%08h read 0x%08h  diff 0x%08h",
                                   $time, element, w, BASE + 4 * w, exp, r, r ^ exp);
      end
      dmi_wr(7'h3C, d);
      ops = ops + 1;
    end
  endtask

  // ---------------- fault injection into byte lane 0 ----------------
  `define SRAM0 dut.i_croc_gen_sram_bank_0__i_sram_i_tc_sram_gen_512x32xBx1_gen_sram_banks_0__i_sram_bank
  reg [8*8-1:0] fault;
  integer fa, fb, fa2;
  initial begin
    fault = "none"; fa = 100; fb = 3; fa2 = 101;
    if ($value$plusargs("fault=%s", fault)) ;
    if ($value$plusargs("fa=%d", fa)) ;
    if ($value$plusargs("fb=%d", fb)) ;
    if ($value$plusargs("fa2=%d", fa2)) ;
  end
  always @(posedge `SRAM0.CLK) begin
    if (fault == "saf0") `SRAM0.mem[fa][fb] = 1'b0;
    if (fault == "saf1") `SRAM0.mem[fa][fb] = 1'b1;
    if ((fault == "cfin" || fault == "af") && !`SRAM0.CEN && !`SRAM0.GWEN && `SRAM0.A == fa) begin
      #0.5;
      if (fault == "cfin") `SRAM0.mem[fa2][fb] = ~`SRAM0.mem[fa2][fb];
      else `SRAM0.mem[fa2] = `SRAM0.mem[fa];
    end
  end

  initial begin
    $timeformat(-9, 0, " ns", 10);
    #2000; rst_n = 1; trst_n = 1; #2000;
    tap_reset;
    shift_dr(32, 64'd0, scan_in);
    if (scan_in[31:0] !== IDCODE) begin $display("JTAG id code 0x%08h: MARCH ABORTED", scan_in[31:0]); $finish; end
    shift_ir(5'h11);
    dmi_wr(7'h10, 32'h0000_0001);                  // dmactive
    dmi_wr(7'h38, 32'h0014_0000);                  // sbreadonaddr, 32-bit
    B0 = 32'h0000_0000;  B1 = 32'hFFFF_FFFF;
    if ($test$plusargs("checker")) begin B0 = 32'h5555_5555; B1 = 32'hAAAA_AAAA; end
    $display("%0t  March C- of %0d words, background 0x%08h / 0x%08h, fault: %0s", $time, NW, B0, B1, fault);
    for (i = 0; i < NW; i = i + 1)        wr(i, B0);                  // element 0:  up   (w0)
    for (i = 0; i < NW; i = i + 1)        rw(i, B0, B1, 1);           // element 1:  up   (r0 w1)
    for (i = 0; i < NW; i = i + 1)        rw(i, B1, B0, 2);           // element 2:  up   (r1 w0)
    for (i = NW - 1; i >= 0; i = i - 1)   rw(i, B0, B1, 3);           // element 3:  down (r0 w1)
    for (i = NW - 1; i >= 0; i = i - 1)   rw(i, B1, B0, 4);           // element 4:  down (r1 w0)
    for (i = 0; i < NW; i = i + 1)        rd(i, B0, 5);               // element 5:  up   (r0)
    if (dmi_err != 0) $display("%0t  WARNING %0d debug-module accesses returned an error status", $time, dmi_err);
    if (errors == 0 && dmi_err == 0) $display("%0t  MARCH PASS: %0d accesses, 0 mismatches", $time, ops);
    else $display("%0t  MARCH FAIL: %0d mismatches in %0d accesses (%0d debug-module errors)", $time, errors, ops, dmi_err);
    $finish;
  end
endmodule
