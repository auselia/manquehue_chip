// Chip-level gate-level test of chip_top with the AC3E padframe (pads included, waferspace_manquehue branch
// aus-113-ac3e-padframe). Two modes:
//   default       boots croc_soc through the JTAG pads (program load into the SRAM) and waits for "GLS OK" on the
//                 UART pad.
//   +flash=<hex>  no JTAG: the QSPI flash model on the QSPI pads holds the program (sim/sw/flash, objcopy -O verilog),
//                 the bootrom finds the image and runs it. The ADS7057 model on the shared SPI pads (CS0, SCK, SD_I)
//                 feeds (1237 * k + 5000) mod 16384 at CS fall k, as rtl/test/tb_croc_soc.sv. The SX1276 model is on
//                 CS1 of the same bus (MISO on SD_I too), DIO0 and RSTN on their pads. Waits for a UART line
//                 that ends in "OK" (for example "SPI ADC OK" from sim/sw/spi/spi_adc.c), fails on "FAIL".
// The test bench drives only what a board would drive. testmode_i, scan_in_i and scan_en_i are left open: the
// pull-downs of the pads must make them read 0. Plain Verilog, runs in Icarus (four-state, so X on a reset path shows up).
`timescale 1ns/1ps
module tb_chip_ac3e;
  parameter NWORDS = 68;
  parameter [31:0] IDCODE = 32'h1C0C_5DB3;

  reg clk = 0, rst_n = 0, ref_clk = 0, tck = 0, tms = 1, tdi = 0, trst_n = 0, uart_rx = 1;
  reg tm_drv = 0, tm_val = 0;                      // tm_drv = 0: the testmode_i pad is left open

  supply1 VDD, DVDD;
  supply0 VSS, DVSS;

  // pad nets (inout ports of chip_top: nets, not regs)
  wire clk_i = clk, rst_ni = rst_n, ref_clk_i = ref_clk, jtag_tck_i = tck, jtag_tms_i = tms, jtag_tdi_i = tdi;
  wire jtag_trst_ni = trst_n, uart_rx_i = uart_rx;
  wire testmode_i, jtag_tdo_o, uart_tx_o, status_o, scan_in_i, scan_en_i, scan_out_o;
  wire qspi_clk_o, qspi_cs0_o, qspi_cs1_o, qspi_cs2_o, qspi_sd0_io, qspi_sd1_io, qspi_sd2_io, qspi_sd3_io;
  wire gpio0_io, gpio1_io, spi_sck_o, spi_sd_o, spi_sd_i, spi_cs0_o, spi_cs1_o, afe_irq_i, rf_dio0_i, rf_rstn_o;

  assign testmode_i = tm_drv ? tm_val : 1'bz;
  // The vendor pad model (in_c) is a plain buffer and ignores PD/PU, so an open pad would float to z.
  // Model what the real pad does: with its PD pin high the pad pulls the line down weakly. PD comes from the pad instance
  // of the placed netlist, so this passes only if chip_top really ties PD of testmode_i high.
  wire tm_pd = dut.pad_testmode_i.PD;
  assign (weak0, highz1) testmode_i = (tm_pd === 1'b1) ? 1'b0 : 1'bz;
  wire tdo = jtag_tdo_o, uart_tx = uart_tx_o, status = status_o;

  // inputs that a board would tie low: the QSPI data lines and the GPIOs
  pulldown (qspi_sd0_io); pulldown (qspi_sd1_io); pulldown (qspi_sd2_io); pulldown (qspi_sd3_io);
  pulldown (gpio0_io);    pulldown (gpio1_io);

  // ---------------- board models of the flash mode ----------------
  // QSPI flash on chip select 0: each data pad carries what the flash drives, else what the chip drives
  wire [3:0] flash_o, flash_oe;
  spi_flash_model i_flash (
    .csn    ( qspi_cs0_o ),
    .sclk   ( qspi_clk_o ),
    .sio_i  ( {qspi_sd3_io, qspi_sd2_io, qspi_sd1_io, qspi_sd0_io} ),
    .sio_o  ( flash_o    ),
    .sio_oe ( flash_oe   )
  );
  assign qspi_sd0_io = flash_oe[0] ? flash_o[0] : 1'bz;
  assign qspi_sd1_io = flash_oe[1] ? flash_o[1] : 1'bz;
  assign qspi_sd2_io = flash_oe[2] ? flash_o[2] : 1'bz;
  assign qspi_sd3_io = flash_oe[3] ? flash_o[3] : 1'bz;
  // ADS7057 on CS0 of the shared SPI bus: its SDO is high impedance while CS0 is high
  wire       adc_sdo;
  reg [13:0] adc_ain = 14'd5000;
  integer    adc_falls = 0;
  ads7057_model i_adc (
    .cs_n     ( spi_cs0_o ),
    .sclk     ( spi_sck_o ),
    .sdo      ( adc_sdo   ),
    .ain_code ( adc_ain   )
  );
  assign spi_sd_i = adc_sdo;
  pulldown (spi_sd_i);
  always @(negedge spi_cs0_o) adc_falls = adc_falls + 1;
  always @(posedge spi_cs0_o) if (adc_falls > 0) adc_ain = (adc_falls * 1237 + 5000) % 16384;
  // SX1276 on CS1: MISO on the shared data input, high impedance while CS1 is high
  wire rf_miso, rf_dio0;
  sx1276_model i_radio (
    .nss_n ( spi_cs1_o ),
    .sclk  ( spi_sck_o ),
    .mosi  ( spi_sd_o  ),
    .miso  ( rf_miso   ),
    .dio0  ( rf_dio0   )
  );
  assign spi_sd_i  = rf_miso;
  assign rf_dio0_i = (rf_dio0 === 1'b1);

  chip_top dut (
    .VDD(VDD), .VSS(VSS),
    .clk_i(clk_i), .rst_ni(rst_ni), .ref_clk_i(ref_clk_i), .testmode_i(testmode_i), .status_o(status_o),
    .jtag_tck_i(jtag_tck_i), .jtag_tms_i(jtag_tms_i), .jtag_tdi_i(jtag_tdi_i), .jtag_trst_ni(jtag_trst_ni),
    .jtag_tdo_o(jtag_tdo_o), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .qspi_clk_o(qspi_clk_o), .qspi_cs0_o(qspi_cs0_o), .qspi_cs1_o(qspi_cs1_o), .qspi_cs2_o(qspi_cs2_o),
    .qspi_sd0_io(qspi_sd0_io), .qspi_sd1_io(qspi_sd1_io), .qspi_sd2_io(qspi_sd2_io), .qspi_sd3_io(qspi_sd3_io),
    .gpio0_io(gpio0_io), .gpio1_io(gpio1_io),
    .spi_sck_o(spi_sck_o), .spi_sd_o(spi_sd_o), .spi_sd_i(spi_sd_i), .spi_cs0_o(spi_cs0_o), .spi_cs1_o(spi_cs1_o),
    .afe_irq_i(afe_irq_i), .rf_dio0_i(rf_dio0_i), .rf_rstn_o(rf_rstn_o),
    .scan_in_i(scan_in_i), .scan_en_i(scan_en_i), .scan_out_o(scan_out_o)
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
  integer nline = 0, uart_ok = 0, uart_fail = 0, ui;
  always @(negedge uart_tx) begin
    #4000;
    for (ui = 0; ui < 8; ui = ui + 1) begin #8000; ch[ui] = uart_tx; end
    #8000;
    $display("%0t  [UART] '%c' (0x%02h)", $time, ch, ch);
    line = {line[8*31-1:0], ch};
    if (line[8*6-1:0] == "GLS OK" || line[8*7-1:8] == "GLS OK") uart_ok = 1;
    if ($test$plusargs("flash")) begin
      if (line[8*2-1:0] == "OK" || line[8*3-1:8] == "OK") uart_ok = 1;
      if (line[8*4-1:0] == "FAIL" || line[8*5-1:8] == "FAIL") uart_fail = 1;
    end
  end

  // ---------------- test ----------------
  reg [31:0] rdata, dmstat;
  reg [31:0] prog [0:NWORDS-1];
  integer k;
  initial begin
    $timeformat(-9, 0, " ns", 10);
    if ($test$plusargs("tm0")) begin tm_drv = 1; tm_val = 0; end   // drive testmode_i low instead of leaving the pad open
    $readmemh("prog_words.hex", prog);
    if ($test$plusargs("flash")) begin
      #2000; rst_n = 1; trst_n = 1;
      $display("%0t  [TB] flash mode: reset released, no JTAG, the bootrom runs the flash image", $time);
      for (k = 0; k < 2000 && !uart_ok && !uart_fail; k = k + 1) #20000;     // up to 40 ms
      if (uart_ok && !uart_fail)
        $display("%0t  [TB] PASS: OK received on the uart_tx pad (flash boot, %0d ADC frames on the SPI pads)", $time, adc_falls);
      else
        $display("%0t  [TB] FAIL: %0s on the uart_tx pad (%0d ADC frames)", $time, uart_fail ? "FAIL" : "no OK", adc_falls);
      $finish;
    end
    #2000; rst_n = 1; trst_n = 1; #2000;
    $display("%0t  [TB] reset released, testmode_i pad open (pad PD pin = %b), scan pads open", $time, tm_pd);
    $display("%0t  [TB] idle SPI pads: SCK %b CS0 %b CS1 %b RSTN %b", $time, spi_sck_o, spi_cs0_o, spi_cs1_o, rf_rstn_o);
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
      $display("%0t  [DBG] uart_tx = %b, status = %b, testmode pad = %b", $time, uart_tx, status, testmode_i);
    end
    $finish;
  end
endmodule
