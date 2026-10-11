// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Based on fft_obi of FFTodile (ETH Zurich and University of Bologna).

// AE-FFT accelerator for the Croc user domain: OBI subordinate (registers), OBI manager (DMA), interrupt.
// 128 real samples from the system SRAM in, spectrum features out.  See doc/spec_fft.tex.
//
// Register offsets (bytes): 00 CTRL, 04 STATUS, 08 SRC_ADDR, 0C DST_ADDR, 10 IRQ_CTRL, 14 CONFIG,
// 18 SETUP0, 1C SETUP1, 20 THRESH, 24 PEAK_BIN, 28 PEAK_POW, 2C BAND_ENERGY, 30 TOTAL_ENERGY,
// 34 TD_ENERGY, 38 TD_PREV, 3C CYCLES.

module fft_hwpe
  import croc_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,

  input  sbr_obi_req_t obi_sbr_req_i,
  output sbr_obi_rsp_t obi_sbr_rsp_o,

  output mgr_obi_req_t obi_mgr_req_o,
  input  mgr_obi_rsp_t obi_mgr_rsp_i,

  output logic irq_o
);

  logic [31:0] src_addr, dst_addr;
  logic        irq_en;
  logic [3:0]  gain_shift, en_shift;
  logic signed [15:0] dc_offset;
  logic [6:0]  kmin, band_lo, band_hi;
  logic [7:0]  band_thr, decay_thr;

  logic        ctrl_start, ctrl_clr_prev;
  logic        start_pulse, abort, dump_en;
  logic        busy, done_pulse, error_pulse, done_q;

  logic        sample_valid, sample_ready, result_valid, result_ready, core_done;
  logic [31:0] sample, result;

  logic        sat, prev_valid, band_ok, decay;
  logic [6:0]  peak_bin;
  logic [31:0] peak_pow, band_energy, total_energy, td_energy, td_prev, cycles;

  assign irq_o = irq_en & done_q;

  fft_hwpe_regs i_regs (
    .clk_i, .rst_ni,
    .obi_sbr_req_i, .obi_sbr_rsp_o,
    .src_addr_o     ( src_addr      ),
    .dst_addr_o     ( dst_addr      ),
    .irq_en_o       ( irq_en        ),
    .gain_shift_o   ( gain_shift    ),
    .en_shift_o     ( en_shift      ),
    .dc_offset_o    ( dc_offset     ),
    .kmin_o         ( kmin          ),
    .band_lo_o      ( band_lo       ),
    .band_hi_o      ( band_hi       ),
    .band_thr_o     ( band_thr      ),
    .decay_thr_o    ( decay_thr     ),
    .ctrl_start_o   ( ctrl_start    ),
    .ctrl_clr_prev_o( ctrl_clr_prev ),
    .busy_i         ( busy          ),
    .done_pulse_i   ( done_pulse    ),
    .error_pulse_i  ( error_pulse   ),
    .sat_i          ( sat           ),
    .prev_valid_i   ( prev_valid    ),
    .band_ok_i      ( band_ok       ),
    .decay_i        ( decay         ),
    .done_o         ( done_q        ),
    .error_o        (               ),
    .peak_bin_i     ( peak_bin      ),
    .peak_pow_i     ( peak_pow      ),
    .band_energy_i  ( band_energy   ),
    .total_energy_i ( total_energy  ),
    .td_energy_i    ( td_energy     ),
    .td_prev_i      ( td_prev       ),
    .cycles_i       ( cycles        )
  );

  fft_hwpe_ctrl i_ctrl (
    .clk_i, .rst_ni,
    .ctrl_start_i          ( ctrl_start   ),
    .src_addr_i            ( src_addr     ),
    .dst_addr_i            ( dst_addr     ),
    .obi_mgr_req_o, .obi_mgr_rsp_i,
    .start_pulse_o         ( start_pulse  ),
    .abort_o               ( abort        ),
    .dump_en_o             ( dump_en      ),
    .core_sample_valid_o   ( sample_valid ),
    .core_sample_o         ( sample       ),
    .core_sample_ready_i   ( sample_ready ),
    .core_result_valid_i   ( result_valid ),
    .core_result_ready_o   ( result_ready ),
    .core_result_i         ( result       ),
    .core_done_i           ( core_done    ),
    .busy_o                ( busy         ),
    .done_pulse_o          ( done_pulse   ),
    .error_pulse_o         ( error_pulse  )
  );

  fft_hwpe_core i_core (
    .clk_i, .rst_ni,
    .start_i        ( start_pulse   ),
    .abort_i        ( abort         ),
    .clr_prev_i     ( ctrl_clr_prev ),
    .gain_shift_i   ( gain_shift    ),
    .en_shift_i     ( en_shift      ),
    .dc_offset_i    ( dc_offset     ),
    .kmin_i         ( kmin          ),
    .band_lo_i      ( band_lo       ),
    .band_hi_i      ( band_hi       ),
    .band_thr_i     ( band_thr      ),
    .decay_thr_i    ( decay_thr     ),
    .dump_en_i      ( dump_en       ),
    .sample_valid_i ( sample_valid  ),
    .sample_ready_o ( sample_ready  ),
    .sample_i       ( sample        ),
    .result_valid_o ( result_valid  ),
    .result_ready_i ( result_ready  ),
    .result_o       ( result        ),
    .busy_o         (               ),
    .done_o         ( core_done     ),
    .sat_o          ( sat           ),
    .prev_valid_o   ( prev_valid    ),
    .band_ok_o      ( band_ok       ),
    .decay_o        ( decay         ),
    .peak_bin_o     ( peak_bin      ),
    .peak_pow_o     ( peak_pow      ),
    .band_energy_o  ( band_energy   ),
    .total_energy_o ( total_energy  ),
    .td_energy_o    ( td_energy     ),
    .td_prev_o      ( td_prev       ),
    .cycles_o       ( cycles        )
  );

endmodule
