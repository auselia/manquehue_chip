// Applies the vector files made by stil_to_vectors.py to croc_soc, cycle by cycle, with the waveforms of the protocol
// (100 ns cycle, outputs strobed at 40 ns), and compares every expected output. Plain Verilog, runs in Icarus.
// The pins, their order in the _pi and _po groups and the sizes come from tb_atpg_pins.vh (stil_to_vectors.py), so the
// test bench follows the port list of the netlist.
// plusargs: +first=<k> +npat=<n> applies patterns k .. k+n-1 (default all); the unload of pattern k-1 is not compared,
// because the chunk starts from a loaded chain. Chunks are independent, so they can run in parallel.
`timescale 1ns/1ps
module tb_atpg;
`include "tb_atpg_pins.vh"

  reg [0:LEN-1] si [0:NPAT], so_exp [0:NPAT], so_mask [0:NPAT];
  reg [NPI-1:0] pi [0:NPAT-1], pi_pulse [0:NPAT-1];
  reg [NPO-1:0] po_exp [0:NPAT-1], po_mask [0:NPAT-1];

  integer errors = 0, compared = 0, pat, j, kb, nprint = 0, maxprint = 40;
  function integer ones(input [NPO-1:0] x);
    integer i;
    begin ones = 0; for (i = 0; i < NPO; i = i + 1) ones = ones + x[i]; end
  endfunction
  reg [NPO-1:0] diff;
  // one 100 ns cycle: inputs at 0, strobe 40, clk_i high 50-70, jtag_tck_i high 75-90, rst_ni low 75-90
  task cycle(input [NPI-1:0] v, input [NPI-1:0] p, input [NPO-1:0] e, input [NPO-1:0] m, input [8*24-1:0] what,
             input integer idx);
    begin
      drive(v);
      #40;
      diff = (po ^ e) & m;
      compared = compared + ones(m);
      if (diff !== {NPO{1'b0}}) begin  // x/z on a compared output counts as a mismatch
        errors = errors + 1;
        for (kb = 0; kb < NPO; kb = kb + 1)
          if (diff[kb] !== 1'b0 && nprint < maxprint) begin
            nprint = nprint + 1;
            // parsed by diagnose.py: kind (shift|capture), pattern, shift position j, output bit (0 = scan_so_o), expected, read
            $display("FAIL kind=%0s pat=%0d j=%0d bit=%0d exp=%b got=%b t=%0t", what, idx, j, kb, e[kb], po[kb], $time);
          end
      end
      #10;
      if (p[PI_CLK_I]) clk_i = 1;
      #20;
      if (p[PI_CLK_I]) clk_i = 0;
      #5;
      if (p[PI_JTAG_TCK_I]) jtag_tck_i = 1;
      if (p[PI_RST_NI]) rst_ni = 0;
      #15;
      if (p[PI_JTAG_TCK_I]) jtag_tck_i = 0;
      if (p[PI_RST_NI]) rst_ni = 1;
      #10;
    end
  endtask

  // bit i of a _pi word is the pin at PI_<pin> (tb_atpg_pins.vh); scan_so_o is the last pin of _po (bit 0)
  integer npat, first;
  reg [NPI-1:0] v, p;
  initial begin
    $readmemb("si.mem", si);
    $readmemb("so_exp.mem", so_exp);
    $readmemb("so_mask.mem", so_mask);
    $readmemb("pi.mem", pi);
    $readmemb("pi_pulse.mem", pi_pulse);
    $readmemb("po_exp.mem", po_exp);
    $readmemb("po_mask.mem", po_mask);
    npat = NPAT;  first = 0;
    if ($value$plusargs("maxprint=%d", maxprint)) ;
    if ($value$plusargs("npat=%d", npat)) ;
    if ($value$plusargs("first=%d", first)) ;
    drive({NPI{1'b0}});
    // test_setup: clk_i = jtag_tck_i = 0, testmode_i = 1, rst_ni = 1, scan_se_i = 0
    v = {NPI{1'b0}};  v[PI_RST_NI] = 1;  v[PI_TESTMODE_I] = 1;
    cycle(v, {NPI{1'b0}}, {NPO{1'b0}}, {NPO{1'b0}}, "test_setup", 0);
    cycle(v, {NPI{1'b0}}, {NPO{1'b0}}, {NPO{1'b0}}, "test_setup", 1);
    for (pat = first; pat <= first + npat; pat = pat + 1) begin
      // load_unload: scan_se_i = 1, then LEN shifts with both clocks pulsed; compares scan_so_o (bit 0 of po)
      v = st;  v[PI_SCAN_SE_I] = 1;  v[PI_CLK_I] = 0;  v[PI_JTAG_TCK_I] = 0;  v[PI_TESTMODE_I] = 1;  v[PI_RST_NI] = 1;
      cycle(v, {NPI{1'b0}}, {NPO{1'b0}}, {NPO{1'b0}}, "load_unload start", pat);
      for (j = 0; j < LEN; j = j + 1) begin
        v[PI_SCAN_SI_I] = si[pat][j];
        p = {NPI{1'b0}};  p[PI_CLK_I] = 1;  p[PI_JTAG_TCK_I] = 1;
        cycle(v, p, {{(NPO-1){1'b0}}, so_exp[pat][j]}, {{(NPO-1){1'b0}}, so_mask[pat][j] & (pat != first)}, "shift", pat);
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
