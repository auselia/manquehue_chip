// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Behavioral model of the ADS7057 (TI SBAS821), 3-wire SPI-compatible
// SAR ADC, for simulation only -- NOT synthesizable. Verifies obi_spi_host
// transactions against the chip's real protocol quirks:
//  - CS falling edge is the sample trigger, not a command byte.
//  - Output is pipelined by exactly one frame (this frame's SDO carries
//    the *previous* frame's conversion result).
//  - SDO changes shortly after SCLK's rising edge; the host samples on
//    the falling edge (SPI Mode 1, not the naive Mode 0 guess).
//  - The 18-clock/24-clock/64-clock frame-length semantics from
//    datasheet section 8.4 (ACQ/CNV/OFFCAL device functional modes).
//
// Purely edge-driven off cs_ni/sclk_i -- no clk_i port, matching the real
// chip, which has none either.

module ads7057_model (
  input  logic cs_ni,     // chip select, active low -- drives ACQ/CNV transitions
  input  logic sclk_i,    // serial clock
  output logic sdo_o,     // serial data out
  output logic sdo_oe_o   // high while selected; lets a testbench resolve a shared pad
);

  // ---------------------------------------------------------------------
  // Verification-only stimulus queue
  // ---------------------------------------------------------------------
  // Each push_sample() call enqueues the code that will be returned by
  // the conversion completing at the *next* 18th SCLK falling edge -- not
  // the frame currently in flight, per the one-frame pipeline.
  logic signed [13:0] sample_q [$];

  task automatic push_sample(input logic signed [13:0] code);
    sample_q.push_back(code);
  endtask

  function automatic logic signed [13:0] pop_sample();
    if (sample_q.size() > 0) begin
      return sample_q.pop_front();
    end else begin
      $warning("%m: sample queue empty at conversion time, returning 0");
      return '0;
    end
  endfunction

  // ---------------------------------------------------------------------
  // Frame state
  // ---------------------------------------------------------------------
  logic signed [13:0] held_result;    // value shifted out during the current frame
  logic signed [13:0] pending_result; // becomes held_result at the next CS falling edge
  int unsigned         bit_index;     // SCLK rising-edge count within the current frame
  int unsigned         fall_count;    // SCLK falling-edge count within the current frame
  logic                conversion_popped_q; // guards against popping twice per frame
  logic                first_frame_q;       // power-up frame gets 24-clock offset-cal semantics

  initial begin
    held_result          = '0;
    pending_result        = '0;
    bit_index             = 0;
    fall_count            = 0;
    conversion_popped_q   = 1'b0;
    first_frame_q         = 1'b1;
  end

  assign sdo_oe_o = ~cs_ni;

  // sdo_o is a single continuous driver off bit_index/held_result (both
  // already registered by the blocks below) rather than its own
  // procedural block -- avoids two always blocks racing to drive the same
  // output on different edges. bit_index==0 (immediately after CS falls,
  // before the first SCLK edge) and ==1 both read as the leading zero;
  // 2..15 are D13..D0; 16+ covers trailing zeros and any extra clocks
  // beyond the real 18-clock frame. Value is don't-care while deselected
  // -- sdo_oe_o (not sdo_o) is what tells a consumer this output is valid.
  assign sdo_o = (!cs_ni && bit_index inside {[2:15]}) ? held_result[15 - bit_index] : 1'b0;

  // ---------------------------------------------------------------------
  // ACQ: sample trigger + frame setup
  // ---------------------------------------------------------------------
  always @(negedge cs_ni) begin
    held_result          = pending_result;
    bit_index             = 0;
    fall_count            = 0;
    conversion_popped_q   = 1'b0;
  end

  // ---------------------------------------------------------------------
  // Frame end: classify length, tri-state SDO
  // ---------------------------------------------------------------------
  always @(posedge cs_ni) begin
    if (first_frame_q && fall_count == 24) begin
      $display("@%0t | [ads7057_model] power-up offset calibration completed (24 clocks)", $time);
    end else if (!first_frame_q && fall_count == 64) begin
      $display("@%0t | [ads7057_model] recalibration completed (64 clocks)", $time);
    end else if (fall_count < 18) begin
      $warning("%m: frame ended after only %0d SCLK falling edges (<18) -- next frame's result is invalid per datasheet section 8.4.2", fall_count);
    end
    first_frame_q = 1'b0;
  end

  // ---------------------------------------------------------------------
  // CNV: advance the bit index on each SCLK rising edge (sdo_o itself is
  // the continuous assign above, driven off this).
  // ---------------------------------------------------------------------
  always @(posedge sclk_i) begin
    if (!cs_ni) bit_index = bit_index + 1;
  end

  // ---------------------------------------------------------------------
  // Falling-edge count: when the real 18-bit frame completes, the
  // conversion "finishes" and the next sample is queued up for delivery
  // on the *next* frame.
  // ---------------------------------------------------------------------
  always @(negedge sclk_i) begin
    if (!cs_ni) begin
      fall_count = fall_count + 1;
      if (fall_count == 18 && !conversion_popped_q) begin
        pending_result       = pop_sample();
        conversion_popped_q  = 1'b1;
      end
    end
  end

endmodule
