// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Register file style follows fft_obi_regs of FFTodile (ETH Zurich and University of Bologna).

// OBI subordinate register file of the AE-FFT accelerator.  Register map: doc/spec_fft.tex.
// Always grants at once.  The response comes one cycle after the request.

module fft_hwpe_regs
  import croc_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,

  input  sbr_obi_req_t obi_sbr_req_i,
  output sbr_obi_rsp_t obi_sbr_rsp_o,

  // configuration to the engine
  output logic [31:0] src_addr_o,
  output logic [31:0] dst_addr_o,
  output logic        irq_en_o,
  output logic [3:0]  gain_shift_o,
  output logic [3:0]  en_shift_o,
  output logic signed [15:0] dc_offset_o,
  output logic [6:0]  kmin_o,
  output logic [6:0]  band_lo_o,
  output logic [6:0]  band_hi_o,
  output logic [7:0]  band_thr_o,
  output logic [7:0]  decay_thr_o,

  // write-decoded strobes
  output logic        ctrl_start_o,
  output logic        ctrl_clr_prev_o,

  // status
  input  logic        busy_i,
  input  logic        done_pulse_i,       // run finished without error
  input  logic        error_pulse_i,
  input  logic        sat_i,              // level, valid at done
  input  logic        prev_valid_i,
  input  logic        band_ok_i,
  input  logic        decay_i,
  output logic        done_o,
  output logic        error_o,

  // results
  input  logic [6:0]  peak_bin_i,
  input  logic [31:0] peak_pow_i,
  input  logic [31:0] band_energy_i,
  input  logic [31:0] total_energy_i,
  input  logic [31:0] td_energy_i,
  input  logic [31:0] td_prev_i,
  input  logic [31:0] cycles_i
);

  typedef enum logic [5:0] {
    RegCtrl        = 6'h00,
    RegStatus      = 6'h01,
    RegSrcAddr     = 6'h02,
    RegDstAddr     = 6'h03,
    RegIrqCtrl     = 6'h04,
    RegConfig      = 6'h05,
    RegSetup0      = 6'h06,
    RegSetup1      = 6'h07,
    RegThresh      = 6'h08,
    RegPeakBin     = 6'h09,
    RegPeakPow     = 6'h0A,
    RegBandEnergy  = 6'h0B,
    RegTotalEnergy = 6'h0C,
    RegTdEnergy    = 6'h0D,
    RegTdPrev      = 6'h0E,
    RegCycles      = 6'h0F
  } reg_addr_e;

  // CONFIG: [3:0] LOG2_N = 7, [15:8] DATA_WIDTH = 16, [16] HAS_DUMP = 1, [31:24] VERSION = 1
  localparam logic [31:0] ConfigValue = 32'h0100_1007;

  logic                                   sbr_req_q;
  logic [31:0]                            sbr_addr_q;
  logic                                   sbr_we_q;
  logic [$bits(obi_sbr_req_i.a.aid)-1:0] sbr_aid_q;

  logic done_q, sat_q, error_q;
  assign done_o  = done_q;
  assign error_o = error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sbr_req_q  <= 1'b0;
      sbr_addr_q <= '0;
      sbr_we_q   <= 1'b0;
      sbr_aid_q  <= '0;
    end else begin
      sbr_req_q  <= obi_sbr_req_i.req;
      sbr_addr_q <= obi_sbr_req_i.a.addr;
      sbr_we_q   <= obi_sbr_req_i.a.we;
      sbr_aid_q  <= obi_sbr_req_i.a.aid;
    end
  end

  assign obi_sbr_rsp_o.gnt          = 1'b1;
  assign obi_sbr_rsp_o.rvalid       = sbr_req_q;
  assign obi_sbr_rsp_o.r.rid        = sbr_aid_q;
  assign obi_sbr_rsp_o.r.err        = 1'b0;
  assign obi_sbr_rsp_o.r.r_optional = '0;

  always_comb begin
    obi_sbr_rsp_o.r.rdata = 32'h0;
    if (sbr_req_q && !sbr_we_q) begin
      unique case (reg_addr_e'(sbr_addr_q[7:2]))
        RegStatus:     obi_sbr_rsp_o.r.rdata = {25'h0, error_q, decay_i, band_ok_i, prev_valid_i, sat_q, done_q, busy_i};
        RegSrcAddr:    obi_sbr_rsp_o.r.rdata = src_addr_o;
        RegDstAddr:    obi_sbr_rsp_o.r.rdata = dst_addr_o;
        RegIrqCtrl:    obi_sbr_rsp_o.r.rdata = {31'h0, irq_en_o};
        RegConfig:     obi_sbr_rsp_o.r.rdata = ConfigValue;
        RegSetup0:     obi_sbr_rsp_o.r.rdata = {dc_offset_o, 4'h0, en_shift_o, 4'h0, gain_shift_o};
        RegSetup1:     obi_sbr_rsp_o.r.rdata = {9'h0, band_hi_o, 1'b0, band_lo_o, 1'b0, kmin_o};
        RegThresh:     obi_sbr_rsp_o.r.rdata = {16'h0, decay_thr_o, band_thr_o};
        RegPeakBin:    obi_sbr_rsp_o.r.rdata = {25'h0, peak_bin_i};
        RegPeakPow:    obi_sbr_rsp_o.r.rdata = peak_pow_i;
        RegBandEnergy: obi_sbr_rsp_o.r.rdata = band_energy_i;
        RegTotalEnergy:obi_sbr_rsp_o.r.rdata = total_energy_i;
        RegTdEnergy:   obi_sbr_rsp_o.r.rdata = td_energy_i;
        RegTdPrev:     obi_sbr_rsp_o.r.rdata = td_prev_i;
        RegCycles:     obi_sbr_rsp_o.r.rdata = cycles_i;
        default:       obi_sbr_rsp_o.r.rdata = 32'h0;
      endcase
    end
  end

  logic wr;
  logic [5:0] wr_reg;
  logic [31:0] wr_data;
  assign wr      = obi_sbr_req_i.req && obi_sbr_req_i.a.we;
  assign wr_reg  = obi_sbr_req_i.a.addr[7:2];
  assign wr_data = obi_sbr_req_i.a.wdata;

  // configuration registers: ignored while busy, so a run always sees one consistent setup
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_addr_o   <= '0;
      dst_addr_o   <= '0;
      irq_en_o     <= 1'b0;
      gain_shift_o <= 4'd3;
      en_shift_o   <= 4'd4;
      dc_offset_o  <= '0;
      kmin_o       <= 7'd3;
      band_lo_o    <= 7'd8;
      band_hi_o    <= 7'd20;
      band_thr_o   <= 8'd179;
      decay_thr_o  <= 8'd192;
    end else if (wr) begin
      unique case (reg_addr_e'(wr_reg))
        RegIrqCtrl: irq_en_o <= wr_data[0];
        RegSrcAddr: if (!busy_i) src_addr_o <= {wr_data[31:2], 2'b00};
        RegDstAddr: if (!busy_i) dst_addr_o <= {wr_data[31:2], 2'b00};
        RegSetup0: if (!busy_i) begin
          gain_shift_o <= wr_data[3:0];
          en_shift_o   <= wr_data[11:8];
          dc_offset_o  <= wr_data[31:16];
        end
        RegSetup1: if (!busy_i) begin
          kmin_o    <= wr_data[6:0];
          band_lo_o <= wr_data[14:8];
          band_hi_o <= wr_data[22:16];
        end
        RegThresh: if (!busy_i) begin
          band_thr_o  <= wr_data[7:0];
          decay_thr_o <= wr_data[15:8];
        end
        default: ;
      endcase
    end
  end

  // sticky status, write-one-to-clear
  logic st_clr_done, st_clr_sat, st_clr_err;
  assign st_clr_done = wr && (reg_addr_e'(wr_reg) == RegStatus) && wr_data[1];
  assign st_clr_sat  = wr && (reg_addr_e'(wr_reg) == RegStatus) && wr_data[2];
  assign st_clr_err  = wr && (reg_addr_e'(wr_reg) == RegStatus) && wr_data[6];

  assign ctrl_start_o    = wr && (reg_addr_e'(wr_reg) == RegCtrl) && wr_data[0];
  assign ctrl_clr_prev_o = wr && (reg_addr_e'(wr_reg) == RegCtrl) && wr_data[1];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      done_q  <= 1'b0;
      sat_q   <= 1'b0;
      error_q <= 1'b0;
    end else begin
      if (st_clr_done) done_q  <= 1'b0;
      if (st_clr_sat)  sat_q   <= 1'b0;
      if (st_clr_err)  error_q <= 1'b0;
      if (ctrl_start_o && !busy_i) begin
        done_q  <= 1'b0;
        error_q <= 1'b0;
      end
      if (done_pulse_i) begin
        done_q <= 1'b1;
        if (sat_i) sat_q <= 1'b1;
      end
      if (error_pulse_i) error_q <= 1'b1;
    end
  end

endmodule
