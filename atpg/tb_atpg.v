// Applies the vector files made by stil_to_vectors.py to croc_soc, cycle by cycle, with the waveforms of the protocol
// (100 ns cycle, outputs strobed at 40 ns), and compares every expected output. Plain Verilog, runs in Icarus.
// plusargs: +first=<k> +npat=<n> applies patterns k .. k+n-1 (default all); the unload of pattern k-1 is not compared,
// because the chunk starts from a loaded chain. Chunks are independent, so they can run in parallel.
`timescale 1ns/1ps
module tb_atpg;
  parameter NPAT = 573, LEN = 3964;

  reg [0:LEN-1] si [0:NPAT], so_exp [0:NPAT], so_mask [0:NPAT];
  reg [16:0] pi [0:NPAT-1], pi_pulse [0:NPAT-1];
  reg [19:0] po_exp [0:NPAT-1], po_mask [0:NPAT-1];

  // pins: order of the _pi group
  reg clk_i = 0, rst_ni = 0, ref_clk_i = 0, testmode_i = 0, jtag_tck_i = 0, jtag_tdi_i = 0, jtag_tms_i = 0, jtag_trst_ni = 0,
      uart_rx_i = 0, scan_si_i = 0, scan_se_i = 0;
  reg [3:0] qspi_sd_i = 0;
  reg [1:0] gpio_i = 0;
  wire status_o, jtag_tdo_o, uart_tx_o, qspi_clk_o, scan_so_o;
  wire [3:0] qspi_sd_o, qspi_sd_en_o;
  wire [2:0] qspi_csn_o;
  wire [1:0] gpio_o, gpio_out_en_o;

  croc_soc dut (.clk_i(clk_i), .rst_ni(rst_ni), .ref_clk_i(ref_clk_i), .testmode_i(testmode_i), .status_o(status_o),
    .jtag_tck_i(jtag_tck_i), .jtag_tdi_i(jtag_tdi_i), .jtag_tdo_o(jtag_tdo_o), .jtag_tms_i(jtag_tms_i),
    .jtag_trst_ni(jtag_trst_ni), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o), .qspi_clk_o(qspi_clk_o),
    .qspi_sd_o(qspi_sd_o), .qspi_sd_i(qspi_sd_i), .qspi_sd_en_o(qspi_sd_en_o), .qspi_csn_o(qspi_csn_o),
    .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_out_en_o(gpio_out_en_o), .scan_si_i(scan_si_i), .scan_se_i(scan_se_i),
    .scan_so_o(scan_so_o));

  wire [19:0] po = {status_o, jtag_tdo_o, uart_tx_o, qspi_clk_o, qspi_sd_o, qspi_sd_en_o, qspi_csn_o, gpio_o,
                    gpio_out_en_o, scan_so_o};
  // input state in the order of _pi; hold values between vectors
  reg [16:0] st;
  task drive(input [16:0] v);
    begin
      st = v;
      {clk_i, rst_ni, ref_clk_i, testmode_i, jtag_tck_i, jtag_tdi_i, jtag_tms_i, jtag_trst_ni, uart_rx_i, qspi_sd_i,
       gpio_i, scan_si_i, scan_se_i} = v;
    end
  endtask

  integer errors = 0, compared = 0, pat, j;
  function integer ones(input [19:0] x);
    integer i;
    begin ones = 0; for (i = 0; i < 20; i = i + 1) ones = ones + x[i]; end
  endfunction
  reg [19:0] diff;
  // one 100 ns cycle: inputs at 0, strobe 40, clk_i high 50-70, jtag_tck_i high 75-90, rst_ni low 75-90
  task cycle(input [16:0] v, input [16:0] p, input [19:0] e, input [19:0] m, input [8*24-1:0] what, input integer idx);
    begin
      drive(v);
      #40;
      diff = (po ^ e) & m;
      compared = compared + ones(m);
      if (diff !== 20'b0) begin  // x/z on a compared output counts as a mismatch
        errors = errors + 1;
        if (errors <= 20) $display("%0t  MISMATCH %0s %0d: outputs %b expected %b mask %b", $time, what, idx, po, e, m);
      end
      #10;
      if (p[16]) clk_i = 1;
      #20;
      if (p[16]) clk_i = 0;
      #5;
      if (p[12]) jtag_tck_i = 1;
      if (p[15]) rst_ni = 0;
      #15;
      if (p[12]) jtag_tck_i = 0;
      if (p[15]) rst_ni = 1;
      #10;
    end
  endtask

  // _pi index i is bit 16-i of the 17-bit word: clk_i = [16], rst_ni = [15], testmode_i = [13], jtag_tck_i = [12], scan_se_i = [0]
  integer npat, first;
  reg [16:0] v, p;
  initial begin
    $readmemb("si.mem", si);
    $readmemb("so_exp.mem", so_exp);
    $readmemb("so_mask.mem", so_mask);
    $readmemb("pi.mem", pi);
    $readmemb("pi_pulse.mem", pi_pulse);
    $readmemb("po_exp.mem", po_exp);
    $readmemb("po_mask.mem", po_mask);
    npat = NPAT;  first = 0;
    if ($value$plusargs("npat=%d", npat)) ;
    if ($value$plusargs("first=%d", first)) ;
    drive(17'b0);
    // test_setup: clk_i = jtag_tck_i = 0, testmode_i = 1, rst_ni = 1, scan_se_i = 0
    v = 17'b0;  v[15] = 1;  v[13] = 1;
    cycle(v, 17'b0, 20'b0, 20'b0, "test_setup", 0);
    cycle(v, 17'b0, 20'b0, 20'b0, "test_setup", 1);
    for (pat = first; pat <= first + npat; pat = pat + 1) begin
      // load_unload: scan_se_i = 1, then LEN shifts with both clocks pulsed; compares scan_so_o (bit 0 of po)
      v = st;  v[0] = 1;  v[16] = 0;  v[12] = 0;  v[13] = 1;  v[15] = 1;
      cycle(v, 17'b0, 20'b0, 20'b0, "load_unload start", pat);
      for (j = 0; j < LEN; j = j + 1) begin
        v[1] = si[pat][j];
        p = 17'b0;  p[16] = 1;  p[12] = 1;
        cycle(v, p, {19'b0, so_exp[pat][j]}, {19'b0, so_mask[pat][j] & (pat != first)}, "shift of pattern", pat);
      end
      if (pat < first + npat) begin
        // capture: the _pi word of the pattern (rest levels, pulses by pi_pulse)
        cycle(pi[pat], pi_pulse[pat], po_exp[pat], po_mask[pat], "capture", pat);
      end
    end
    if (errors == 0) $display("%0t  PASS: %0d patterns applied, %0d output values compared, 0 mismatches", $time, npat, compared);
    else $display("%0t  FAIL: %0d mismatches in %0d patterns (%0d values compared)", $time, errors, npat, compared);
    $finish;
  end
endmodule
