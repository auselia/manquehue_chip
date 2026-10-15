// Chip-level gate-level test of chip_top (pads included): boots croc_soc through the JTAG pins and waits for "GLS OK" on the UART pin.
// The test bench drives only what a board would drive. testmode_i, scan_si_i and scan_se_i are left open: the pull-downs of
// the pads must make them read 0.  Plain Verilog, runs in Icarus (four-state, so X on a reset path shows up).
`timescale 1ns/1ps
module tb_chip;
  parameter NWORDS = 68;
  parameter [31:0] IDCODE = 32'h1C0C_5DB3;

  reg clk = 0, rst_n = 0, ref_clk = 0, tck = 0, tms = 1, tdi = 0, trst_n = 0, uart_rx = 1;
  reg tm_drv = 0, tm_val = 0;                      // tm_drv = 0: the testmode_i pad is left open

  supply1 VDD, DVDD;
  supply0 VSS, DVSS;
  wire [3:0]  input_PAD;
  wire [43:0] bidir_PAD;
  wire [5:0]  analog_PAD;

  assign input_PAD[0] = ref_clk;
  assign input_PAD[1] = tm_drv ? tm_val : 1'bz;    // testmode_i
  // The vendor pad model (in_c) is a plain buffer and ignores PD/PU, so an open pad would float to z.
  // Model what the real pad does: with its PD pin high the pad pulls the line down weakly. PD comes from the pad instance
  // of the placed netlist, so this passes only if the template really ties PD of testmode_i high.
  wire tm_pd = dut.\inputs[1].pad .PD;
  assign (weak0, highz1) input_PAD[1] = (tm_pd === 1'b1) ? 1'b0 : 1'bz;
  assign input_PAD[2] = tck;                       // jtag_tck_i
  assign input_PAD[3] = tms;                       // jtag_tms_i
  assign bidir_PAD[13] = tdi;                      // jtag_tdi_i
  assign bidir_PAD[14] = trst_n;                   // jtag_trst_ni
  assign bidir_PAD[15] = uart_rx;                  // uart_rx_i

  wire tdo = bidir_PAD[1];                         // jtag_tdo_o
  wire uart_tx = bidir_PAD[2];                     // uart_tx_o
  wire status = bidir_PAD[0];                      // status_o

  // inputs that a board would tie low: qspi_sd[3:0] (7..10) and gpio[1:0] (11, 12)
  pulldown (bidir_PAD[7]);  pulldown (bidir_PAD[8]);  pulldown (bidir_PAD[9]);  pulldown (bidir_PAD[10]);
  pulldown (bidir_PAD[11]); pulldown (bidir_PAD[12]);

  wire clk_PAD, rst_n_PAD;                         // inout ports: connect nets, not regs
  assign clk_PAD = clk;
  assign rst_n_PAD = rst_n;

  chip_top dut (
    .VDD(VDD), .VSS(VSS),
    .clk_PAD(clk_PAD), .rst_n_PAD(rst_n_PAD),
    .input_PAD(input_PAD), .bidir_PAD(bidir_PAD), .analog_PAD(analog_PAD)
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
  always @(dut.\i_chip_core.uart_tx_o ) $display("%0t  [DBG] macro uart_tx_o -> %b", $time, dut.\i_chip_core.uart_tx_o );
  always @(dut.net9) $display("%0t  [DBG] net9 (pad A) -> %b", $time, dut.net9);
  initial begin #3000; $display("%0t  [DBG] macro uart_tx_o = %b, pad A = %b, pad = %b", $time, dut.\i_chip_core.uart_tx_o , dut.net9, uart_tx); end

  // ---------------- test ----------------
  reg [31:0] rdata, dmstat;
  reg [31:0] prog [0:NWORDS-1];
  integer k;
  initial begin
    $timeformat(-9, 0, " ns", 10);
    if ($test$plusargs("tm0")) begin tm_drv = 1; tm_val = 0; end   // drive testmode_i low instead of leaving the pad open
    $readmemh("prog_words.hex", prog);
    #2000; rst_n = 1; trst_n = 1; #2000;
    $display("%0t  [TB] reset released, testmode_i pad open (pad PD pin = %b), scan pads open", $time, tm_pd);
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
    dmi_wr(7'h10, 32'h4000_0001);                  // resumereq
    $display("%0t  [JTAG] resumed", $time);
    for (k = 0; k < 200 && !uart_ok; k = k + 1) #20000;
    if (uart_ok) $display("%0t  [TB] PASS: GLS OK received on the uart_tx pad", $time);
    else begin
      $display("%0t  [TB] FAIL: no GLS OK on the uart_tx pad", $time);
      // look inside through the debug module
      read_reg32(32'h1000_0000, rdata); $display("%0t  [DBG] sram[0]      = 0x%08h (program word 0x%08h)", $time, rdata, prog[0]);
      read_reg32(32'h1000_0030, rdata); $display("%0t  [DBG] sram[0x30]   = 0x%08h (program word 0x%08h)", $time, rdata, prog[12]);
      for (k = 0; k < 8; k = k + 1) begin
        read_reg32(32'h0300_2000 + 4*k, rdata); $display("%0t  [DBG] uart reg%0d    = 0x%08h", $time, k, rdata);
      end
      for (k = 0; k < 6; k = k + 1) begin
        read_reg32(32'h0300_0000 + 4*k, rdata); $display("%0t  [DBG] soc_ctrl[%0d]  = 0x%08h", $time, k, rdata);
      end
      read_reg32(32'h0204_0000, rdata); $display("%0t  [DBG] clint msip   = 0x%08h", $time, rdata);
      dmi_rd(7'h11, dmstat);            $display("%0t  [DBG] dmstatus     = 0x%08h (allhalted %0d, allrunning %0d)", $time, dmstat, dmstat[9], dmstat[11]);
      $display("%0t  [DBG] uart_tx = %b, status = %b, testmode at core = %b", $time, uart_tx, status, dut.input_PAD[1]);
    end
    $finish;
  end
endmodule
