// Behavioural model of the TI ADS7057 (14-bit SAR ADC, 2.5 MSPS, SPI), written from the facts collected in
// Auselia_AFE_v1/doc/SPI_design_handoff.md (datasheet SBAS821). Simulation only. Not a timing model.
//
// What it models
//   - CS falling edge takes the sample of `ain_code` (14-bit two's complement). The result of that sample is shifted
//     out in the NEXT frame: the first frame after power-up returns zeros.
//   - Frame content, MSB first: a leading 0, D13 .. D0, then zeros up to the end of the frame.
//   - A frame with 24 SCLK rising edges after power-up starts the offset calibration (flag `cal_done`); a frame of
//     64 SCLK edges starts a recalibration (counted in `recal_count`).
//   - The conversion needs 18 SCLK falling edges: a frame with fewer edges returns the sample but is flagged in
//     `short_frame_count`; the next frame then also returns zeros (the conversion did not finish).
//   - CS must stay high for at least TACQ_NS (95 ns) between frames, else `tacq_violations` counts up.
//
// ASSUMPTIONS TO CHECK AGAINST THE DATASHEET (open item 1 of the SPI spec)
//   - LAUNCH_ON_FALLING: 1 = SDO changes on SCLK falling edges (the usual TI SAR scheme, host samples on the next
//     rising edge); 0 = SDO changes on rising edges (the handoff states "SPI mode 1: CPOL 0, CPHA 1", which implies
//     this). The model supports both, the spec requires the reader to be configurable for both.
//   - First data bit is driven as soon as CS falls (MSB is the leading 0).
`timescale 1ns/1ps
module ads7057_model #(
  parameter LAUNCH_ON_FALLING = 1,
  parameter real TACQ_NS = 95.0,
  parameter real TCO_NS  = 12.0           // SDO delay after the launching edge
) (
  input  wire        cs_n,
  input  wire        sclk,
  output wire        sdo,
  input  wire [13:0] ain_code            // two's complement code of the input at the moment CS falls
);
  reg [23:0] shift = 24'd0;               // frame shift register, bit 23 first
  reg [13:0] held  = 14'd0;               // sample taken at the previous CS fall
  reg        held_valid = 1'b0;           // a sample exists (false after power-up)
  reg        sdo_r = 1'b0;
  integer    rise = 0, fall = 0;
  integer    frames = 0, short_frame_count = 0, recal_count = 0, tacq_violations = 0;
  reg        cal_done = 1'b0;
  reg        conv_ok = 1'b0;              // previous frame had at least 18 falling edges
  realtime   t_cs_rise = 0.0;

  assign #(TCO_NS) sdo = (cs_n) ? 1'bz : sdo_r;

  always @(negedge cs_n) begin
    if (frames > 0 && ($realtime - t_cs_rise) < TACQ_NS) tacq_violations = tacq_violations + 1;
    // result of the sample taken at the previous CS fall; zeros after power-up or after a short frame
    if (held_valid && conv_ok) shift = {1'b0, held, 9'd0};
    else                       shift = 24'd0;
    held = ain_code;                      // new sample
    held_valid = 1'b1;
    rise = 0; fall = 0;
    sdo_r = shift[23];
  end

  always @(posedge cs_n) begin
    t_cs_rise = $realtime;
    frames = frames + 1;
    conv_ok = (fall >= 18);
    if (fall < 18) short_frame_count = short_frame_count + 1;
    if (!cal_done && rise >= 24 && frames == 1) cal_done = 1'b1;
    if (rise >= 64) recal_count = recal_count + 1;
  end

  always @(posedge sclk) if (!cs_n) begin
    rise = rise + 1;
    if (!LAUNCH_ON_FALLING) begin shift = {shift[22:0], 1'b0}; sdo_r = shift[23]; end
  end
  always @(negedge sclk) if (!cs_n) begin
    fall = fall + 1;
    if (LAUNCH_ON_FALLING) begin shift = {shift[22:0], 1'b0}; sdo_r = shift[23]; end
  end
endmodule
