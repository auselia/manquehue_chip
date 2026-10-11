// Copyright (c) 2026 Auselia
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DMA sequencing follows fft_obi_ctrl of FFTodile (ETH Zurich and University of Bologna).

// Transfer controller: reads 64 words from SRC_ADDR, lets the core run, and writes the 65-bin dump to DST_ADDR
// when DST_ADDR is not zero.  The A phase of every request depends only on registers that do not change
// before gnt, so req and address stay stable as OBI requires.
//
// An OBI error response aborts the run: the controller waits for the outstanding responses, aborts the
// core, and pulses error_pulse_o without done_pulse_o.

module fft_hwpe_ctrl
  import croc_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,

  input  logic        ctrl_start_i,
  input  logic [31:0] src_addr_i,
  input  logic [31:0] dst_addr_i,

  output mgr_obi_req_t obi_mgr_req_o,
  input  mgr_obi_rsp_t obi_mgr_rsp_i,

  // core
  output logic        start_pulse_o,
  output logic        abort_o,
  output logic        dump_en_o,
  output logic        core_sample_valid_o,
  output logic [31:0] core_sample_o,
  input  logic        core_sample_ready_i,
  input  logic        core_result_valid_i,
  output logic        core_result_ready_o,
  input  logic [31:0] core_result_i,
  input  logic        core_done_i,

  output logic        busy_o,
  output logic        done_pulse_o,
  output logic        error_pulse_o
);

  localparam int unsigned FetchWords = 64;
  localparam int unsigned StoreWords = 65;
  localparam int unsigned AidWidth   = $bits(obi_mgr_req_o.a.aid);

  typedef enum logic [1:0] {StateIdle, StateFetch, StateRun, StateDrain} state_e;
  state_e state_q;

  logic [6:0] req_cnt_q, rsp_cnt_q;      // shared by fetch and store, cleared on state change
  logic       dump_q;
  logic       err_q;
  logic       core_done_q;

  logic rsp_err, gnt, rvalid;
  assign gnt     = obi_mgr_rsp_i.gnt;
  assign rvalid  = obi_mgr_rsp_i.rvalid;
  assign rsp_err = rvalid && obi_mgr_rsp_i.r.err;

  assign start_pulse_o = ctrl_start_i && (state_q == StateIdle);
  assign dump_en_o     = dump_q;
  assign busy_o        = (state_q != StateIdle);

  assign core_sample_valid_o = (state_q == StateFetch) && rvalid && !err_q && !rsp_err;
  assign core_sample_o       = obi_mgr_rsp_i.r.rdata;
  assign core_result_ready_o = (state_q == StateRun) && obi_mgr_req_o.req && gnt;

  logic [31:0] fetch_addr, store_addr;
  assign fetch_addr = src_addr_i + {23'h0, req_cnt_q, 2'b00};
  assign store_addr = dst_addr_i + {23'h0, req_cnt_q, 2'b00};

  always_comb begin
    obi_mgr_req_o      = '0;
    obi_mgr_req_o.a.be = 4'hF;
    unique case (state_q)
      StateFetch: begin
        if (req_cnt_q < FetchWords && core_sample_ready_i && !err_q) begin
          obi_mgr_req_o.req    = 1'b1;
          obi_mgr_req_o.a.we   = 1'b0;
          obi_mgr_req_o.a.addr = fetch_addr;
          obi_mgr_req_o.a.aid  = AidWidth'(req_cnt_q);
        end
      end
      StateRun: begin
        if (dump_q && req_cnt_q < StoreWords && core_result_valid_i && !err_q) begin
          obi_mgr_req_o.req     = 1'b1;
          obi_mgr_req_o.a.we    = 1'b1;
          obi_mgr_req_o.a.addr  = store_addr;
          obi_mgr_req_o.a.wdata = core_result_i;
          obi_mgr_req_o.a.aid   = AidWidth'(req_cnt_q);
        end
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= StateIdle;
      req_cnt_q     <= '0;
      rsp_cnt_q     <= '0;
      dump_q        <= 1'b0;
      err_q         <= 1'b0;
      core_done_q   <= 1'b0;
      abort_o       <= 1'b0;
      done_pulse_o  <= 1'b0;
      error_pulse_o <= 1'b0;
    end else begin
      abort_o       <= 1'b0;
      done_pulse_o  <= 1'b0;
      error_pulse_o <= 1'b0;

      unique case (state_q)
        StateIdle: begin
          if (start_pulse_o) begin
            state_q     <= StateFetch;
            req_cnt_q   <= '0;
            rsp_cnt_q   <= '0;
            dump_q      <= (dst_addr_i != 32'h0);
            err_q       <= 1'b0;
            core_done_q <= 1'b0;
          end
        end

        StateFetch: begin
          if (obi_mgr_req_o.req && gnt) req_cnt_q <= req_cnt_q + 1'b1;
          if (rvalid) rsp_cnt_q <= rsp_cnt_q + 1'b1;
          if (rsp_err) err_q <= 1'b1;
          if (err_q || rsp_err) begin
            state_q <= StateDrain;
          end else if (rvalid && rsp_cnt_q == FetchWords - 1) begin
            state_q   <= StateRun;
            req_cnt_q <= '0;
            rsp_cnt_q <= '0;
          end
        end

        StateRun: begin
          if (obi_mgr_req_o.req && gnt) req_cnt_q <= req_cnt_q + 1'b1;
          if (rvalid) rsp_cnt_q <= rsp_cnt_q + 1'b1;
          if (core_done_i) core_done_q <= 1'b1;
          if (rsp_err) begin
            err_q   <= 1'b1;
            state_q <= StateDrain;
          end else if ((core_done_q || core_done_i) &&
                       (!dump_q || (rsp_cnt_q + {6'h0, rvalid}) == StoreWords)) begin
            state_q      <= StateIdle;
            done_pulse_o <= 1'b1;
          end
        end

        StateDrain: begin
          // wait for every request that was granted to get its response, then give up
          abort_o <= 1'b1;
          if (rvalid) rsp_cnt_q <= rsp_cnt_q + 1'b1;
          if (obi_mgr_req_o.req && gnt) req_cnt_q <= req_cnt_q + 1'b1;
          if (rsp_cnt_q + {6'h0, rvalid} == req_cnt_q) begin
            state_q       <= StateIdle;
            error_pulse_o <= 1'b1;
          end
        end

        default: state_q <= StateIdle;
      endcase
    end
  end

endmodule
