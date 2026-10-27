// Gate-level scan-shift test of the croc_soc macro netlist.
//
// Puts the macro in shift state (testmode_i = 1, scan_se_i = 1), toggles both shift clocks with the
// waveforms declared to the DFT tool (set_dft_signal -type ScanClock in scripts/common/dft_scan.tcl:
// clk_i rises at 50 ns and falls at 70 ns, jtag_tck_i rises at 75 ns and falls at 90 ns, 100 ns
// period) and pushes a pseudo-random bit stream through scan_si_i. A working chain returns the same
// stream on scan_so_o, delayed by exactly the number of scan cells, inverted if the chain has an odd number of
// inverters (+expected_inv=1, from scripts/sim/scan_chain_trace.py). The test finds that delay and requires it to be
// EXPECTED_LAG with zero mismatches over the whole stream, with the expected polarity.
//
// +rst_low drives rst_ni and jtag_trst_ni low during the shift: the asynchronous resets must stay
// held inactive by the AutoFix gate (testmode_i), so the stream must come out unchanged.
//
// usage (run scripts/sim/run_gls_scan.sh): Vscan [+rst_low | +rstn_low | +trstn_low] [+expected_lag=N]
//        [+expected_inv=0|1] [+nbits=N]
// +rstn_low drives only rst_ni low, +trstn_low only jtag_trst_ni.
`timescale 1ns/1ps

module tb_scan_shift;
  localparam int unsigned DefaultLag  = 3964;   // scan cells in the chain (dft_drc: "Chain 1 ... 3964 scan_cells")
  localparam int unsigned DefaultBits = 12000;  // length of the pseudo-random stream

  logic clk_i = 0, jtag_tck_i = 0;
  logic rst_ni = 1, jtag_trst_ni = 1, testmode_i = 0, scan_se_i = 0, scan_si_i = 0;
  wire  scan_so_o;
  wire  status_o, jtag_tdo_o, uart_tx_o, qspi_clk_o;
  wire  [3:0] qspi_sd_o, qspi_sd_en_o;
  wire  [2:0] qspi_csn_o;
  wire  [1:0] gpio_o, gpio_out_en_o;

  croc_soc i_croc_soc (
    .clk_i         ( clk_i        ),
    .rst_ni        ( rst_ni       ),
    .ref_clk_i     ( 1'b0         ),
    .testmode_i    ( testmode_i   ),
    .status_o      ( status_o     ),
    .jtag_tck_i    ( jtag_tck_i   ),
    .jtag_tdi_i    ( 1'b0         ),
    .jtag_tdo_o    ( jtag_tdo_o   ),
    .jtag_tms_i    ( 1'b0         ),
    .jtag_trst_ni  ( jtag_trst_ni ),
    .uart_rx_i     ( 1'b1         ),
    .uart_tx_o     ( uart_tx_o    ),
    .qspi_clk_o    ( qspi_clk_o   ),
    .qspi_sd_o     ( qspi_sd_o    ),
    .qspi_sd_i     ( 4'b0         ),
    .qspi_sd_en_o  ( qspi_sd_en_o ),
    .qspi_csn_o    ( qspi_csn_o   ),
    .spi_sck_o     (              ),
    .spi_sd_o      (              ),
    .spi_sd_i      ( 1'b0         ),
    .spi_cs0_o     (              ),
    .spi_cs1_o     (              ),
    .afe_irq_i     ( 1'b1         ),
    .rf_dio0_i     ( 1'b0         ),
    .rf_rstn_o     (              ),
    .gpio_i        ( 2'b0         ),
    .gpio_o        ( gpio_o       ),
    .gpio_out_en_o ( gpio_out_en_o),
    .scan_si_i     ( scan_si_i    ),
    .scan_se_i     ( scan_se_i    ),
    .scan_so_o     ( scan_so_o    )
  );

  int unsigned nbits, expected_lag, expected_inv;
  bit rst_low;
  bit stream_in  [];
  bit stream_out [];
  logic [31:0] lfsr;

  function automatic bit next_bit();
    // 32-bit Galois LFSR, taps 32 22 2 1
    bit b = lfsr[0];
    lfsr = (lfsr >> 1) ^ (b ? 32'h80200003 : 32'h0);
    return b;
  endfunction

  task automatic shift_cycle(input int unsigned i);
    scan_si_i = stream_in[i];
    #50 clk_i = 1;
    #20 clk_i = 0;
    #5  jtag_tck_i = 1;
    #15 jtag_tck_i = 0;
    stream_out[i] = scan_so_o;  // sampled 95 ns into the cycle, after both shift edges
    #5;
  endtask

  initial begin
    if (!$value$plusargs("nbits=%d", nbits)) nbits = DefaultBits;
    if (!$value$plusargs("expected_lag=%d", expected_lag)) expected_lag = DefaultLag;
    if (!$value$plusargs("expected_inv=%d", expected_inv)) expected_inv = 0;
    rst_low = $test$plusargs("rst_low");
    stream_in  = new[nbits];
    stream_out = new[nbits];
    lfsr = 32'hACE1_2468;
    for (int unsigned i = 0; i < nbits; i++) stream_in[i] = next_bit();

    // shift state, then settle
    testmode_i = 1;
    scan_se_i  = 1;
    if (rst_low || $test$plusargs("rstn_low"))   rst_ni = 0;
    if (rst_low || $test$plusargs("trstn_low"))  jtag_trst_ni = 0;
    #1000;

    for (int unsigned i = 0; i < nbits; i++) shift_cycle(i);

    // dump both streams for offline analysis (one character per cycle)
    begin
      int fd;
      string name;
      name = rst_low ? "scan_io_rst_low.txt" : ($test$plusargs("rstn_low") ? "scan_io_rstn_low.txt" : ($test$plusargs("trstn_low") ? "scan_io_trstn_low.txt" : "scan_io.txt"));
      fd = $fopen(name, "w");
      for (int unsigned i = 0; i < nbits; i++) $fwrite(fd, "%0d", stream_in[i]);
      $fwrite(fd, "\n");
      for (int unsigned i = 0; i < nbits; i++) $fwrite(fd, "%0d", stream_out[i]);
      $fwrite(fd, "\n");
      $fclose(fd);
    end

    // find the delay between scan_si_i and scan_so_o: out[j] == in[j - lag + 1] for a chain of `lag` cells
    begin
      int unsigned best_lag, best_miss, first;
      // assigned here, not in the declaration: declaration initializers run once at time 0, before the plusargs are read
      best_lag  = 0;
      best_miss = nbits;
      first     = expected_lag + 64;  // skip the part of the output that still holds the power-up state
      for (int unsigned lag = 1; lag < expected_lag + 64; lag++) begin
        int unsigned miss;
        miss = 0;
        for (int unsigned j = first; j < nbits; j++)
          if (stream_out[j] !== (stream_in[j - lag + 1] ^ bit'(expected_inv))) miss++;
        if (miss < best_miss) begin best_miss = miss; best_lag = lag; end
      end
      $display("SCAN_SHIFT rst_low=%0d bits=%0d compared=%0d best_lag=%0d mismatches=%0d expected_lag=%0d inverted=%0d",
               rst_low, nbits, nbits - first, best_lag, best_miss, expected_lag, expected_inv);
      if (best_lag == expected_lag && best_miss == 0) $display("SCAN_SHIFT_RESULT PASS");
      else                                             $display("SCAN_SHIFT_RESULT FAIL");
    end
    $finish;
  end
endmodule
