// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
// - Enrico Zelioli <ezelioli@iis.ee.ethz.ch>

// Waveform dump: define TRACE_WAVE to get croc.fst (scripts/sim/run_verilator.sh does it with TRACE=1).
// It is off by default: a full dump of a long firmware run reaches tens of GB.

module tb_croc_soc #(
  parameter int unsigned GpioCount = 32
);

  import tb_croc_pkg::*;

  // Signals fully controlled by the VIP
  // use VIP functions/tasks to manipulate these signals
  logic rst_n;
  logic sys_clk;
  logic ref_clk;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_rx;
  logic uart_tx;

  // Signals partially controlled by the VIP
  logic [GpioCount-1:0] gpio_in;
  logic [GpioCount-1:0] gpio_out;
  logic [GpioCount-1:0] gpio_out_en;

  // Signals controlled by the testbench

  /////////////////////////////
  //  Command Line Arguments //
  /////////////////////////////

  string binary_path;

  initial begin
    // $value$plusargs defines what to look for (here +binary=...)
    if ($value$plusargs("binary=%s", binary_path)) begin
      $display("Running program: %s", binary_path);
    end else begin
      $display("No binary path provided. Running helloworld.");
      binary_path = "../sw/hello_world/bin/helloworld.hex";
    end
  end

  ////////////
  //  VIP   //
  ////////////
  // Verification IP
  // - drives clocks and resets
  // - provides helper tasks and functions for JTAG, namely:
  //   - jtag_load_hex: loads a hex file into the DUT's memory
  //   - jtag_write_reg32: write 32-bit value to DUT
  //   - jtag_read_reg32: read 32-bit value from DUT
  //   - jtag_halt / jtag_resume: control core execution
  //   - jtag_wait_for_eoc: wait for end of code execution (core writes non-zero to status register)
  // - prints UART output to console (you can also write via uart_write_byte)
  // - internal GPIO loopback for helloworld test

  croc_vip #(
    .GpioCount ( GpioCount )
  ) i_vip (
    .rst_no        ( rst_n       ),
    .sys_clk_o     ( sys_clk     ),
    .ref_clk_o     ( ref_clk     ),
    .jtag_tck_o    ( jtag_tck    ),
    .jtag_trst_no  ( jtag_trst_n ),
    .jtag_tms_o    ( jtag_tms    ),
    .jtag_tdi_o    ( jtag_tdi    ),
    .jtag_tdo_i    ( jtag_tdo    ),
    .uart_rx_o     ( uart_rx     ),
    .uart_tx_i     ( uart_tx     ),
    .gpio_out_en_i ( gpio_out_en ),
    .gpio_out_i    ( gpio_out    ),
    .gpio_in_o     ( gpio_in     )
  );

  // QSPI flash (sim/models/spi_flash_model.v) on chip select 0. +flash=<hex> loads an image (objcopy -O verilog,
  // addresses relative to 0x2000_0000). Without it the flash reads erased and the bootrom waits for JTAG.
  wire       qspi_clk_o;
  wire [3:0] qspi_sd_o, qspi_sd_en_o;
  wire [2:0] qspi_csn_o;
  wire [3:0] qspi_sd_i;
  wire [3:0] flash_sio_o, flash_sio_oe;
  spi_flash_model i_flash (
    .csn    ( qspi_csn_o[0]              ),
    .sclk   ( qspi_clk_o                 ),
    .sio_i  ( qspi_sd_o & qspi_sd_en_o   ),
    .sio_o  ( flash_sio_o                ),
    .sio_oe ( flash_sio_oe               )
  );
  // each data line carries what the flash drives, else what the SoC drives (0 when nobody drives)
  assign qspi_sd_i = (flash_sio_o & flash_sio_oe) | (qspi_sd_o & qspi_sd_en_o & ~flash_sio_oe);

  ////////////
  //  DUT   //
  ////////////

  `ifdef TARGET_NETLIST_YOSYS
  \croc_soc$croc_chip.i_croc_soc i_croc_soc (
  `else
  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
  `endif
    .clk_i         ( sys_clk     ),
    .rst_ni        ( rst_n       ),
    .ref_clk_i     ( ref_clk     ),
    .testmode_i    ( 1'b0        ),
    .status_o      (             ),
    .jtag_tck_i    ( jtag_tck    ),
    .jtag_tdi_i    ( jtag_tdi    ),
    .jtag_tdo_o    ( jtag_tdo    ),
    .jtag_tms_i    ( jtag_tms    ),
    .jtag_trst_ni  ( jtag_trst_n ),
    .uart_rx_i     ( uart_rx     ),
    .uart_tx_o     ( uart_tx     ),
    .gpio_i        ( gpio_in     ),
    .gpio_o        ( gpio_out    ),
    .gpio_out_en_o ( gpio_out_en ),

    .qspi_clk_o    ( qspi_clk_o   ),
    .qspi_sd_o     ( qspi_sd_o    ),
    .qspi_sd_i     ( qspi_sd_i    ),
    .qspi_sd_en_o  ( qspi_sd_en_o ),
    .qspi_csn_o    ( qspi_csn_o   ),

    .adc_sclk_o     ( adc_sclk    ),
    .adc_csn_o      ( adc_csn     ),
    .adc_sdo_i      ( adc_sdo_in  ),
    .adc_wake_n_i   ( 1'b1        ),
    .adc_big_n_i    ( 1'b1        ),
    .adc_wake_clr_o (             ),
    .adc_cap_en_o   (             ),
    .rf_sclk_o      (             ),
    .rf_mosi_o      (             ),
    .rf_miso_i      ( 1'b0        ),
    .rf_csn_o       (             ),
    .rf_dio0_i      ( 1'b0        ),
    .rf_rstn_o      (             )
  );

  // ADS7057 model on the ADC pins (sim/models/ads7057_model.v). The sample taken at CS fall k is
  // (1237 * k + 5000) mod 16384, so two consecutive samples differ by 1237 mod 2^14 (sim/sw/spi_adc checks this).
  wire         adc_sclk, adc_csn, adc_sdo;
  logic        adc_sdo_in;
  logic [13:0] adc_ain = 14'd5000;
  int unsigned adc_falls = 0;
  assign adc_sdo_in = (adc_sdo === 1'b1);
  ads7057_model i_adc_model (
    .cs_n     ( adc_csn  ),
    .sclk     ( adc_sclk ),
    .sdo      ( adc_sdo  ),
    .ain_code ( adc_ain  )
  );
  always @(negedge adc_csn) adc_falls++;
  always @(posedge adc_csn) if (adc_falls > 0) adc_ain = 14'((adc_falls * 1237 + 5000) % 16384);

  /////////////////
  //  Testbench  //
  /////////////////

  logic [31:0] tb_data;

  initial begin
    $timeformat(-9, 0, "ns", 12); // 1: scale (ns=-9), 2: decimals, 3: suffix, 4: print-field width

    // wait for reset
    #ClkPeriodSys;

    // init jtag
    i_vip.jtag_init();

    if ($test$plusargs("flash")) begin
      // flash boot: the bootrom found the image magic and runs the program from the QSPI flash.
      // No JTAG load: the program's data and stack are in the SRAM.
      $display("@%t | [CORE] Program in the QSPI flash, no JTAG load", $time);
    end else begin
      // write test value to sram
      i_vip.jtag_write_reg32(SramBaseAddr, 32'h1234_5678, 1'b1);

      // load binary to sram
      i_vip.jtag_load_hex(binary_path);

      // wake core from WFI by writing to CLINT msip
      $display("@%t | [CORE] Waking core via CLINT msip", $time);
      i_vip.jtag_write_reg32(ClintBaseAddr, 32'h1);

      // halt core
      i_vip.jtag_halt();

      // resume core
      i_vip.jtag_resume();
    end

    // wait for non-zero return value (written into core status register)
    $display("@%t | [CORE] Wait for end of code...", $time);
    i_vip.jtag_wait_for_eoc(tb_data);

    // finish simulation
    repeat(50) @(posedge sys_clk);
    $finish();
  end

  ////////////////
  //  Waveform  //
  ////////////////
  // start waveform dump at time 0, independent of stimuli
  initial begin
    `ifdef TRACE_WAVE
      `ifdef VERILATOR
        $dumpfile("croc.fst");
        $dumpvars(0, i_croc_soc);
      `else
        $dumpfile("croc.vcd");
        $dumpvars(0, i_croc_soc);
      `endif
    `endif
  end

  // flush waveform dump when simulation ends
  final begin
    `ifdef TRACE_WAVE
      $dumpflush;
    `endif
  end

endmodule
