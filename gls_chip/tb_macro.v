// Chip-level gate-level test of chip_top (pads included): boots croc_soc through the JTAG pins and waits for "GLS OK" on the UART pin.
// The test bench drives only what a board would drive. testmode_i, scan_si_i and scan_se_i are left open: the pull-downs of
// the pads must make them read 0.  Plain Verilog, runs in Icarus (four-state, so X on a reset path shows up).
`timescale 1ns/1ps
module tb_macro;
  parameter NWORDS = 68;
  parameter [31:0] IDCODE = 32'h1C0C_5DB3;

  reg clk = 0, rst_n = 0, ref_clk = 0, tck = 0, tms = 1, tdi = 0, trst_n = 0, uart_rx = 1;
  reg tm_drv = 0, tm_val = 0;                      // tm_drv = 0: the testmode_i pad is left open

  supply1 VDD;
  supply0 VSS;
  wire tdo, uart_tx, status;
  wire scan_so;
  wire tm = tm_drv ? tm_val : 1'b0;               // the macro has no pad: testmode_i is driven low

  croc_soc dut (
    .VDD(VDD), .VSS(VSS),
    .clk_i(clk), .rst_ni(rst_n), .ref_clk_i(ref_clk), .testmode_i(tm), .status_o(status),
    .jtag_tck_i(tck), .jtag_tdi_i(tdi), .jtag_tdo_o(tdo), .jtag_tms_i(tms), .jtag_trst_ni(trst_n),
    .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
    .qspi_clk_o(), .qspi_sd_o(), .qspi_sd_i(4'b0000), .qspi_sd_en_o(), .qspi_csn_o(),
    .gpio_i(2'b00), .gpio_o(), .gpio_out_en_o(),
    .scan_si_i(1'b0), .scan_se_i(1'b0), .scan_so_o(scan_so)
  );

  always #25 clk = ~clk;                           // 20 MHz
  always #15259 ref_clk = ~ref_clk;                // 32 kHz

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
        #5 din[i] = tdo;                           // TDO changes after the falling edge (flop and pad delay): sample 5 ns later
        jclk(i == n - 1, dout[i]);
      end
      jclk(1, 0); jclk(0, 0);
    end
  endtask
  reg [63:0] scan_in;
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
      if (scan_in[1:0] != 2'd0) $display("%0t  [JTAG] WARNING dmi status %0d on read of 0x%0h", $time, scan_in[1:0], a);
    end
  endtask
  task write_reg32(input [31:0] a, input [31:0] d);
    begin
      dmi_wr(7'h38, 32'h0004_0000);                // sbaccess = 32 bit
      dmi_wr(7'h39, a);
      dmi_wr(7'h3C, d);
    end
  endtask
  task read_reg32(input [31:0] a, output [31:0] d);
    begin
      dmi_wr(7'h38, 32'h0014_0000);                // sbreadonaddr, sbaccess = 32 bit
      dmi_wr(7'h39, a);
      dmi_rd(7'h3C, d);
    end
  endtask

  // ---------------- UART monitor, 125 kBd (20 MHz / (10 * 16)) ----------------
  reg [7:0] ch;
  reg [8*32-1:0] line;
  integer nline = 0, uart_ok = 0, ui;
  always @(negedge uart_tx) begin
    #4000;
    for (ui = 0; ui < 8; ui = ui + 1) begin #8000; ch[ui] = uart_tx; end
    #8000;
    $display("%0t  [UART] '%c' (0x%02h)", $time, ch, ch);
    line = {line[8*31-1:0], ch};
    if (line[8*6-1:0] == "GLS OK" || line[8*7-1:8] == "GLS OK") uart_ok = 1;
  end

  always @(uart_tx) $display("%0t  [DBG] uart_tx -> %b", $time, uart_tx);

  integer nbaud = 0;
  always @(posedge dut.i_croc_i_uart_baud_rate_edge) nbaud = nbaud + 1;
  reg sample_en = 0;
  integer nacc = 0;
  always @(posedge dut.i_croc_gen_sram_bank_0__i_sram_i_tc_sram_gen_512x32xBx1_gen_sram_banks_0__i_sram_bank.CLK)
    if (sample_en && !dut.i_croc_gen_sram_bank_0__i_sram_i_tc_sram_gen_512x32xBx1_gen_sram_banks_0__i_sram_bank.CEN && nacc < 150) begin
      nacc = nacc + 1;
      $display("%0t  [SRAM0] word address 0x%03h  GWEN=%b", $time, dut.i_croc_gen_sram_bank_0__i_sram_i_tc_sram_gen_512x32xBx1_gen_sram_banks_0__i_sram_bank.A, dut.i_croc_gen_sram_bank_0__i_sram_i_tc_sram_gen_512x32xBx1_gen_sram_banks_0__i_sram_bank.GWEN);
    end

  // ---------------- test ----------------
  reg [31:0] rdata, dmstat;
  reg [31:0] prog [0:NWORDS-1];
  integer k;
  initial begin
    $timeformat(-9, 0, " ns", 10);
    if ($test$plusargs("tm0")) begin tm_drv = 1; tm_val = 0; end   // drive testmode_i low instead of leaving the pad open
    $readmemh("prog_words.hex", prog);
    #2000; rst_n = 1; trst_n = 1; #2000;
    $display("%0t  [TB] reset released, testmode_i pad open, scan pads open", $time);
    tap_reset;
    shift_dr(32, 64'd0, scan_in);
    if (scan_in[31:0] === IDCODE) $display("%0t  [JTAG] ID code 0x%08h ok", $time, scan_in[31:0]);
    else begin $display("%0t  [JTAG] FAIL id code 0x%08h", $time, scan_in[31:0]); $finish; end
    shift_ir(5'h11);                               // DMI access
    dmi_wr(7'h10, 32'h0000_0001);                  // dmactive
    dmi_rd(7'h10, rdata);
    $display("%0t  [JTAG] dmcontrol = 0x%08h", $time, rdata);
    write_reg32(32'h1000_0000, 32'h1234_5678);
    read_reg32(32'h1000_0000, rdata);
    if (rdata === 32'h1234_5678) $display("%0t  [JTAG] SRAM write and read back ok through the pads", $time);
    else begin $display("%0t  [JTAG] FAIL SRAM read back 0x%08h", $time, rdata); $finish; end
    dmi_wr(7'h38, 32'h0005_0000);                  // autoincrement, 32 bit
    dmi_wr(7'h39, 32'h1000_0000);
    for (k = 0; k < NWORDS; k = k + 1) dmi_wr(7'h3C, prog[k]);
    $display("%0t  [JTAG] program loaded (%0d words)", $time, NWORDS);
    write_reg32(32'h0204_0000, 32'h1);             // CLINT msip: wake the core
    $display("%0t  [CORE] woken via CLINT msip", $time);
    dmi_wr(7'h10, 32'h8000_0001);                  // haltreq
    dmstat = 0;
    for (k = 0; k < 50 && !dmstat[9]; k = k + 1) dmi_rd(7'h11, dmstat);
    $display("%0t  [JTAG] halted: allhalted = %0d", $time, dmstat[9]);
    sample_en = 1;
    dmi_wr(7'h10, 32'h4000_0001);                  // resumereq
    $display("%0t  [JTAG] resumed", $time);
    for (k = 0; k < 200 && !uart_ok; k = k + 1) #20000;
    if (uart_ok) $display("%0t  [TB] PASS: GLS OK received on the uart_tx pad", $time);
    else begin
      $display("%0t  [TB] FAIL: no GLS OK on the uart_tx pad", $time);
      // look inside through the debug module
      read_reg32(32'h1000_0000, rdata); $display("%0t  [DBG] sram[0]      = 0x%08h (program word 0x%08h)", $time, rdata, prog[0]);
      read_reg32(32'h1000_0030, rdata); $display("%0t  [DBG] sram[0x30]   = 0x%08h (program word 0x%08h)", $time, rdata, prog[12]);
      $display("%0t  [UARTREG] dlab=%b word_len={%b,%b} fifo_en=%b dll=%b%b%b%b%b%b%b%b dlm=%b%b%b%b%b%b%b%b", $time,
        dut.i_croc_i_uart_reg_read_lcr__dlab_, dut.i_croc_i_uart_reg_read_lcr__word_len__1_, dut.i_croc_i_uart_reg_read_lcr__word_len__0_, dut.i_croc_i_uart_reg_read_fcr__fifo_en_,
        dut.i_croc_i_uart_reg_read_dll__lsb__7_, dut.i_croc_i_uart_reg_read_dll__lsb__6_, dut.i_croc_i_uart_reg_read_dll__lsb__5_, dut.i_croc_i_uart_reg_read_dll__lsb__4_, dut.i_croc_i_uart_reg_read_dll__lsb__3_, dut.i_croc_i_uart_reg_read_dll__lsb__2_, dut.i_croc_i_uart_reg_read_dll__lsb__1_, dut.i_croc_i_uart_reg_read_dll__lsb__0_,
        dut.i_croc_i_uart_reg_read_dlm__msb__7_, dut.i_croc_i_uart_reg_read_dlm__msb__6_, dut.i_croc_i_uart_reg_read_dlm__msb__5_, dut.i_croc_i_uart_reg_read_dlm__msb__4_, dut.i_croc_i_uart_reg_read_dlm__msb__3_, dut.i_croc_i_uart_reg_read_dlm__msb__2_, dut.i_croc_i_uart_reg_read_dlm__msb__1_, dut.i_croc_i_uart_reg_read_dlm__msb__0_);
      $display("%0t  [UARTREG] baud edges seen = %0d", $time, nbaud);
      for (k = 0; k < 8; k = k + 1) begin
        read_reg32(32'h0300_2000 + 4*k, rdata); $display("%0t  [DBG] uart reg%0d    = 0x%08h", $time, k, rdata);
      end
      for (k = 0; k < 6; k = k + 1) begin
        read_reg32(32'h0300_0000 + 4*k, rdata); $display("%0t  [DBG] soc_ctrl[%0d]  = 0x%08h", $time, k, rdata);
      end
      read_reg32(32'h0204_0000, rdata); $display("%0t  [DBG] clint msip   = 0x%08h", $time, rdata);
      dmi_rd(7'h11, dmstat);            $display("%0t  [DBG] dmstatus     = 0x%08h (allhalted %0d, allrunning %0d)", $time, dmstat, dmstat[9], dmstat[11]);
      $display("%0t  [DBG] uart_tx = %b, status = %b", $time, uart_tx, status);
    end
    $finish;
  end
endmodule
