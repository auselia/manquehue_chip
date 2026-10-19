// RTL simulation of the forwarded-clock frame engine against the ADS7057 behavioural model.
`timescale 1ns/1ps
module tb_fwd_clk_toy_gls;
  parameter SAMPLE_DLY = 0;
  reg clk = 0, rst_n = 0, run = 0;
  reg [13:0] ain = 14'd0;
  wire sclk, csn, sdo;
  wire [13:0] code;
  wire valid;
  always #27.5 clk = ~clk;                 // 55 ns, the sign-off clock

  fwd_clk_toy dut (.clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .run_i(run),
    .adc_sclk_o(sclk), .adc_csn_o(csn), .adc_sdo_i(sdo), .code_o(code), .valid_o(valid));
  // board delay on SDO as seen at the chip pin: model delay (TCO 8 ns) plus 6 ns of pad, translator and trace
  wire sdo_adc;
  ads7057_model adc (.cs_n(csn), .sclk(sclk), .sdo(sdo_adc), .ain_code(ain));
  assign #6 sdo = sdo_adc;

  integer n = 0, errors = 0, frames = 0;
  reg [13:0] cur = 14'd0, prev = 14'd0;
  always @(posedge csn) ain <= ain + 14'd517;       // new input code after every frame, stable at the next CS fall
  always @(negedge csn) begin                       // the model samples `ain` here
    frames = frames + 1;
    prev <= cur;
    cur  <= ain;
  end
  always @(posedge valid) begin
    #1;                                             // the gated clock of code_o in the netlist is a few delta cycles later
    // the result read in this frame is the sample taken at the previous CS fall
    if (code !== prev) begin errors = errors + 1; $display("%0t  MISMATCH frame %0d: got 0x%04h expected 0x%04h", $time, frames, code, prev); end
    n = n + 1;
  end

  initial begin
    #200 rst_n = 1; #200 run = 1;
    wait (n >= 30);
    run = 0;
    #4000;
    $display("frames %0d, results checked %0d, mismatches %0d", frames, n, errors);
    $display("adc model: short %0d, tacq violations %0d, tsu %0d, tht %0d, tph %0d, duty %0d",
             adc.short_frame_count, adc.tacq_violations, adc.tsu_violations, adc.tht_violations, adc.tph_violations, adc.duty_violations);
    if (errors == 0 && n >= 30 && adc.short_frame_count == 0 && adc.tacq_violations == 0 && adc.tsu_violations == 0 && adc.tht_violations == 0)
      $display("PASS: forwarded clock frames read back correctly (SAMPLE_DLY=%0d)", SAMPLE_DLY);
    else $display("FAIL");
    $finish;
  end
endmodule
