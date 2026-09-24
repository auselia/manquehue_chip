// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Top-level testbench for verifying obi_spi_host <-> ADS7057 transactions
// against ads7057_model.sv, attached to croc_soc's real (shared) pads --
// mirrors tb_croc_soc.sv's VIP/JTAG-load/wait-for-eoc structure, plus the
// ADC model and its pad wiring.
//
// Pad sharing: per croc_soc.sv's pinmux, this project's firmware wiring
// puts the ADS7057 on CS1 (see sim/sw/ads7057_test/main.c) -- CS1/MOSI ride
// on the gpio0/gpio1 pads (gpio_out[0]/gpio_out[1]) once pinmux_sel[1] is
// set, SCLK rides on uart_tx_o, and MISO is always fanned out onto
// uart_rx_i regardless of which chip-select is active (see the pin-budget
// note in croc_soc.sv). The model is wired to those existing pins directly
// -- pinmux_sel itself is not a top-level croc_soc port and does not need
// to be.

`define TRACE_WAVE

module tb_ads7057 #(
  // Matches tb_croc_soc.sv's default, not croc_soc.sv's real-hardware
  // default of 2 -- croc_vip.sv's internal GPIO loopback logic has
  // hardcoded bit-slices (gpio_in_o[7:4], gpio_in_o[GpioCount-1:8], ...)
  // that are only in-range for GpioCount >= 16. A smaller GpioCount here
  // produces genuinely out-of-range selects in the VIP (confirmed via a
  // lint run's SELRANGE warnings), which was observed to cascade into a
  // spurious JTAG system-bus error during jtag_halt/resume -- unrelated to
  // the ADS7057 model itself. The pinmux logic under test only ever
  // touches gpio_out[0]/gpio_out[1] regardless of GpioCount, so simulating
  // extra unused GPIO pins here doesn't affect what's being verified.
  parameter int unsigned GpioCount = 32
);

  import tb_croc_pkg::*;

  logic rst_n;
  logic sys_clk;
  logic ref_clk;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_rx;      // croc_soc's uart_rx_i -- shared with ADS7057 MISO
  logic uart_tx;      // croc_soc's uart_tx_o -- shared with ADS7057 SCLK
  logic vip_uart_rx;  // what the VIP itself wants to drive on uart_rx

  logic status_o;

  logic [GpioCount-1:0] gpio_in;
  logic [GpioCount-1:0] gpio_out;
  logic [GpioCount-1:0] gpio_out_en;

  // QSPI flash pins -- unused by this test (firmware is JTAG-loaded into
  // SRAM, not booted from flash), tied off / left dangling.
  logic       qspi_clk_o;
  logic [3:0] qspi_sd_o;
  logic [3:0] qspi_sd_en_o;
  logic [2:0] qspi_csn_o;
  logic [3:0] qspi_sd_i;
  assign qspi_sd_i = 4'h0;

  ////////////////////
  //  ADS7057 model //
  ////////////////////

  logic ads7057_sdo, ads7057_sdo_oe;

  ads7057_model i_ads7057 (
    .cs_ni    ( gpio_out[0]     ), // CS1 -- see wiring note above
    .sclk_i   ( uart_tx         ),
    .sdo_o    ( ads7057_sdo     ),
    .sdo_oe_o ( ads7057_sdo_oe  )
  );

  // Shared-pad resolution: the VIP's own UART RX driver idles high and
  // only toggles inside uart_write_byte, which this test never calls
  // during the SPI window (croc_vip.sv's default uart_rx_o = 1'b1). A real
  // PCB needs an external switch/analog mux doing the equivalent; this
  // assign stands in for that in simulation.
  assign uart_rx = ads7057_sdo_oe ? ads7057_sdo : vip_uart_rx;

  ////////////
  //  VIP   //
  ////////////

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
    .uart_rx_o     ( vip_uart_rx ),
    .uart_tx_i     ( uart_tx     ),
    .gpio_out_en_i ( gpio_out_en ),
    .gpio_out_i    ( gpio_out    ),
    .gpio_in_o     ( gpio_in     )
  );

  ////////////
  //  DUT   //
  ////////////

  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
    .clk_i         ( sys_clk     ),
    .rst_ni        ( rst_n       ),
    .ref_clk_i     ( ref_clk     ),
    .testmode_i    ( 1'b0        ),
    .status_o      ( status_o    ),
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
    .qspi_csn_o    ( qspi_csn_o   )
  );

  /////////////////
  //  Testbench  //
  /////////////////

  string binary_path;

  initial begin
    if ($value$plusargs("binary=%s", binary_path)) begin
      $display("Running program: %s", binary_path);
    end else begin
      $display("No binary path provided. Running ads7057_test.");
      binary_path = "../sw/ads7057_test/bin/main.hex";
    end
  end

  // Known codes for the model to hand back, in read order. main.c issues
  // one throwaway read first (see its comment on the one-frame pipeline),
  // so the first entry here is never checked against printed output --
  // it exists only to give that throwaway read a defined, non-X result.
  localparam int unsigned NumTestSamples = 6;
  logic signed [13:0] test_samples [NumTestSamples];

  logic [31:0] tb_data;

  initial begin
    $timeformat(-9, 0, "ns", 12);

    test_samples[0] = 14'sd0;      // consumed by the throwaway read
    test_samples[1] = 14'sd100;
    test_samples[2] = -14'sd200;
    test_samples[3] = 14'sd8191;   // PFSC, max positive code
    test_samples[4] = -14'sd8192;  // NFSC, max negative code
    test_samples[5] = 14'sd0;      // MC, mid code

    for (int i = 0; i < NumTestSamples; i++) i_ads7057.push_sample(test_samples[i]);

    // wait for reset
    #ClkPeriodSys;

    // init jtag
    i_vip.jtag_init();

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

    // wait for non-zero return value (written into core status register)
    $display("@%t | [CORE] Wait for end of code...", $time);
    i_vip.jtag_wait_for_eoc(tb_data);

    // No JTAG-readback self-check here -- that would need a real linker
    // symbol address for a firmware results buffer, which main.c doesn't
    // currently export. For now, correctness is checked by eye (or by
    // grepping the run log) against the "code = ..." lines main.c prints
    // for test_samples[1:5], plus the automatic protocol checks
    // (<18-clock frame warning, empty-queue warning) inside ads7057_model
    // itself firing on any run.

    // finish simulation
    repeat(50) @(posedge sys_clk);
    $finish();
  end

  ////////////////
  //  Waveform  //
  ////////////////

  initial begin
    `ifdef TRACE_WAVE
      `ifdef VERILATOR
        $dumpfile("ads7057.fst");
        $dumpvars(0, i_croc_soc);
        $dumpvars(0, i_ads7057);
      `else
        $dumpfile("ads7057.vcd");
        $dumpvars(0, i_croc_soc);
        $dumpvars(0, i_ads7057);
      `endif
    `endif
  end

  final begin
    `ifdef TRACE_WAVE
      $dumpflush;
    `endif
  end

endmodule
