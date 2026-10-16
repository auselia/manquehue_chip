// Behavioural model of the TI ADS7057 (14-bit SAR ADC, SPI), written from the datasheet SBAS821 (December 2017):
// section 8.4 (functional modes), figures 1, 2, 37, 38, 39 and tables 6.6, 6.7. Simulation only, no analog.
//
//   - CS falling edge takes the sample of `ain_code` (14-bit two's complement). The result is shifted out in the NEXT
//     frame. The first frame after power-up outputs all zeros.
//   - A leading 0 is on SDO from CS falling (tden_CSDO <= 6.5 ns). The MSB (D13) is launched on the first SCLK rising
//     edge AFTER the first SCLK falling edge. Every following bit is launched on the following rising edges, then
//     zeros after D0. The host samples on the falling edges (SCLK idle high, falling edge number 1 reads the leading 0).
//   - Conversion needs 18 SCLK falling edges. With fewer, the result of the next frame is invalid (modelled as zeros,
//     counted in `short_frame_count`).
//   - First frame after power-up with 24 SCLKs: offset calibration (`cal_done`), SDO zero. A frame with 64 SCLKs in
//     normal operation: recalibration (`recal_count`), the first 18 bits carry the result as usual.
//   - Timing checks (counted, not enforced): tsu_CSCK 7 ns (CS fall to first SCLK fall), tht_CKCS 8 ns (SCLK rise to
//     CS rise), CS high 15 ns, tACQ 95 ns (last conversion clock to next CS fall), SCLK high and low 45 to 55 % of the
//     period, SCLK period 16.66 ns. SDO delay: td_CKDO 10 ns max after a rising edge, tht_CKDO 2.5 ns.
`timescale 1ns/1ps
module ads7057_model #(
  parameter real TACQ_NS  = 95.0,
  parameter real TCO_NS   = 8.0,          // SDO delay after the launching rising edge (datasheet max 10 ns)
  parameter real TSU_CSCK = 7.0,
  parameter real THT_CKCS = 8.0,
  parameter real TPH_CS   = 15.0
) (
  input  wire        cs_n,
  input  wire        sclk,
  output wire        sdo,
  input  wire [13:0] ain_code            // two's complement code of the input at the moment CS falls
);
  reg [13:0] held  = 14'd0;               // sample taken at the previous CS fall
  reg        held_ok = 1'b0;              // the result of that sample is valid (false after power-up or a short frame)
  reg [13:0] out_code = 14'd0;
  reg        out_valid = 1'b0;
  integer    k = 0;                       // position in the output sequence of the frame (0 = leading zero)
  integer    rise = 0, fall = 0;
  integer    frames = 0, short_frame_count = 0, recal_count = 0;
  integer    tacq_violations = 0, tsu_violations = 0, tht_violations = 0, tph_violations = 0, duty_violations = 0;
  reg        cal_done = 1'b0;
  realtime   t_cs_fall = 0.0, t_cs_rise = 0.0, t_last_fall = 0.0, t_last_rise = 0.0, t_conv_end = 0.0, t_prev_edge = 0.0;
  reg        sdo_r = 1'b0;
  assign #(TCO_NS) sdo = cs_n ? 1'bz : sdo_r;

  function bit_at(input integer idx);    // idx 0: leading zero, 1..14: D13..D0, above: zero
    begin
      if (idx >= 1 && idx <= 14 && out_valid) bit_at = out_code[14 - idx];
      else                                    bit_at = 1'b0;
    end
  endfunction

  always @(negedge cs_n) begin
    t_cs_fall = $realtime;
    if (frames > 0) begin
      if (($realtime - t_conv_end) < TACQ_NS) tacq_violations = tacq_violations + 1;
      if (($realtime - t_cs_rise) < TPH_CS)   tph_violations = tph_violations + 1;
    end
    out_code = held; out_valid = held_ok;     // result of the previous sample
    held = ain_code;                          // new sample
    rise = 0; fall = 0; k = 0;
    sdo_r = 1'b0;                             // leading 0
  end

  always @(negedge sclk) if (!cs_n) begin
    fall = fall + 1;
    if (fall == 1 && ($realtime - t_cs_fall) < TSU_CSCK) tsu_violations = tsu_violations + 1;
    t_last_fall = $realtime;
    if (fall == 18) t_conv_end = $realtime;
  end

  always @(posedge sclk) if (!cs_n) begin
    rise = rise + 1;
    t_last_rise = $realtime;
    if (fall >= 1) begin                      // launching starts with the first rising edge after the first falling edge
      k = k + 1;
      sdo_r = bit_at(k);
    end
  end

  always @(posedge cs_n) begin
    t_cs_rise = $realtime;
    if (fall >= 1 && ($realtime - t_last_rise) < THT_CKCS) tht_violations = tht_violations + 1;
    frames = frames + 1;
    held_ok = (fall >= 18) && !(frames == 1 && rise >= 24);   // short frame or calibration frame: no valid result
    if (fall < 18) short_frame_count = short_frame_count + 1;
    if (frames == 1 && rise >= 24) cal_done = 1'b1;
    if (frames > 1 && rise >= 64) recal_count = recal_count + 1;
    if (fall < 18) t_conv_end = $realtime;
  end

  // duty cycle of SCLK while CS is low: 45 to 55 % of the previous period
  always @(posedge sclk) if (!cs_n && t_prev_edge != 0.0) begin
    if (($realtime - t_last_fall) < 0.45 * ($realtime - t_prev_edge) || ($realtime - t_last_fall) > 0.55 * ($realtime - t_prev_edge))
      duty_violations = duty_violations + 1;
  end
  always @(negedge sclk) t_prev_edge = $realtime;
endmodule
