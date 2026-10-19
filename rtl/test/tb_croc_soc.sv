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
    .adc_wake_n_i   ( adc_wake_n  ),
    .adc_big_n_i    ( 1'b1        ),
    .adc_wake_clr_o (             ),
    .adc_cap_en_o   (             ),
    .rf_sclk_o      ( rf_sclk     ),
    .rf_mosi_o      ( rf_mosi     ),
    .rf_miso_i      ( rf_miso_in  ),
    .rf_csn_o       ( rf_csn      ),
    .rf_dio0_i      ( rf_dio0     ),
    .rf_rstn_o      ( rf_rstn     )
  );

  // ADS7057 model on the ADC pins (sim/models/ads7057_model.v). The sample taken at CS fall k is
  // (1237 * k + 5000) mod 16384, so two consecutive samples differ by 1237 mod 2^14 (sim/sw/spi_adc checks this).
  // +adc_tone=<b>: a tone at FFT bin b instead, round(3000 sin(2 pi b k / 128)) + ((1237 k) mod 61) - 30. The small
  // dither makes every block different, so sim/sw/flash/check_ae_node.py finds each block from its first two samples.
  // +adc_file=<hex> +adc_len=<n>: a recorded code stream instead (14-bit codes, one per line, sample k at CS fall k + 1),
  // and +adc_wake_frame=<n>: WAKE_N goes low at CS fall n for 20 frames (sim/sw/flash/ae_cav.c, check_ae_cav.py).
  // +adc_timebase=1: the stream runs in time instead, one sample per 20 clocks (a frame at IDLE 2) from the first CS
  // fall, and WAKE_N goes low at stream sample n. For a reader that takes no samples before the trigger (ADC_TRIG.START).
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
  int  adc_tone = -1;
  int  adc_nfile = 0, adc_wake_frame = 0, adc_timebase = 0, adc_cyc = -1;
  logic [13:0] adc_stream [0:4095];
  logic adc_wake_n = 1'b1;
  string adc_file;
  initial begin
    void'($value$plusargs("adc_wake_frame=%d", adc_wake_frame));
    void'($value$plusargs("adc_len=%d", adc_nfile));
    void'($value$plusargs("adc_timebase=%d", adc_timebase));
    if ($value$plusargs("adc_file=%s", adc_file) && adc_nfile > 0) begin
      $readmemh(adc_file, adc_stream, 0, adc_nfile - 1);
      $display("@%t | [ADC] code stream %s, %0d samples, WAKE_N at frame %0d", $time, adc_file, adc_nfile, adc_wake_frame);
    end
  end
  real adc_t1000 = 0.0;
  initial void'($value$plusargs("adc_tone=%d", adc_tone));
  function automatic logic [13:0] tone_code(int k);
    real v;
    v = 3000.0 * $sin(2.0 * 3.141592653589793 * real'(adc_tone) * real'(k) / 128.0);
    return 14'($rtoi(v >= 0.0 ? v + 0.5 : v - 0.5) + ((k * 1237) % 61) - 30);
  endfunction
  always @(posedge adc_csn) if (adc_falls > 0 && adc_timebase == 0)
    adc_ain = (adc_nfile > 0) ? adc_stream[adc_falls < adc_nfile ? adc_falls : adc_nfile - 1] :
              (adc_tone >= 0) ? tone_code(adc_falls) : 14'((adc_falls * 1237 + 5000) % 16384);
  always @(negedge adc_csn) if (adc_wake_frame > 0 && adc_timebase == 0) begin
    if (adc_falls + 1 == adc_wake_frame) adc_wake_n = 1'b0;
    if (adc_falls + 1 == adc_wake_frame + 20) adc_wake_n = 1'b1;
  end
  always @(negedge adc_csn) if (adc_cyc < 0) adc_cyc = 0;
  always @(posedge sys_clk) if (adc_timebase != 0 && adc_nfile > 0 && adc_cyc >= 0) begin
    adc_cyc++;
    adc_ain = adc_stream[adc_cyc / 20 < adc_nfile ? adc_cyc / 20 : adc_nfile - 1];
    if (adc_wake_frame > 0 && adc_cyc / 20 == adc_wake_frame) adc_wake_n = 1'b0;
    if (adc_wake_frame > 0 && adc_cyc / 20 == adc_wake_frame + 20) adc_wake_n = 1'b1;
  end
  // sample rate on the pins: time of 1000 frames
  always @(negedge adc_csn) begin
    if (adc_falls == 1000) adc_t1000 = $realtime;
    if (adc_falls == 2000)
      $display("@%t | [ADC] 1000 frames in %0.1f ns: %0.1f kS/s, model timing violations tacq %0d tsu %0d tph %0d",
               $time, $realtime - adc_t1000, 1.0e9 / ($realtime - adc_t1000),
               i_adc_model.tacq_violations, i_adc_model.tsu_violations, i_adc_model.tph_violations);
  end

  // SX1276 model on the radio pins (sim/models/sx1276_model.v, SPI mode 0). MISO is high impedance while NSS is
  // high and reads 0 then. The model has no reset input: rf_rstn is only printed.
  wire  rf_sclk, rf_mosi, rf_miso, rf_csn, rf_dio0, rf_rstn;
  logic rf_miso_in;
  assign rf_miso_in = (rf_miso === 1'b1);
  sx1276_model i_rf_model (
    .nss_n ( rf_csn  ),
    .sclk  ( rf_sclk ),
    .mosi  ( rf_mosi ),
    .miso  ( rf_miso ),
    .dio0  ( rf_dio0 )
  );
  always @(posedge rf_rstn) $display("@%t | [RF] radio out of reset", $time);
  always @(posedge rf_dio0) begin
    $write("@%t | [RF] TX done, payload %0d bytes:", $time, i_rf_model.last_tx_len);
    for (int k = 0; k < i_rf_model.last_tx_len && k < 32; k++) $write(" %02h", i_rf_model.last_tx[k]);
    $display("");
  end

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
