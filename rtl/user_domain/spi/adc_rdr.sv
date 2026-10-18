// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// ADS7057 reader of the SPI block (docs/spi_adc_spec.md section 5). Reads the ADC with no CPU in the loop and writes
// the samples, two per 32-bit word, into two SRAM buffers through the OBI manager port.
//
// Frame (one state per SCLK period, state c = 0 .. LEN+IDLE-1):
//   CS low in states 0..LEN, SCLK falls at the start of states 1..LEN (LEN falling edges: 18, 24 for the calibration
//   frame, 64 for a recalibration), CS high from state LEN+1, the next CS fall is IDLE states after the LEN-th falling
//   edge. The host samples SDO on the SCLK falling edges: edge 1 reads the leading 0, edges 2..15 read D13..D0.
//   A frame returns the sample taken at the previous CS fall, so the first result after the calibration frame or after
//   a pause is discarded.
// SCLK:
//   - default: the system clock through a clock gate (obi_spi_clk_gate) and an inverter. SCLK idles high and falls at
//     the rising edge of clk_i. SDO is captured by a rising-edge flop half a clock after the ADC launched it.
//   - SDO_NEG: SDO is captured by a falling-edge flop of clk_i, half a clock later (more setup margin, the hold margin
//     is the ADC's own hold time plus the board delay). This is the only falling-edge flop of the block.
//   - SCLK_HALF: SCLK is a flop toggling at clk/2, no forwarded clock (fallback, half the sample rate).
//   - testmode_i: SCLK is held high.
// Configuration (frame length, IDLE, SDO_NEG, SCLK_HALF) is taken at the start of every frame.
//
// Register map (word offsets of the ADC block, byte offsets 0x100 + 4 x word):
//   0 ADC_CTRL    RW    [0] EN [1] RUN [2] TRIGGERED [3] SW_TRIG (W1, self-clearing) [4] CAL (W1, self-clearing)
//                       [5] SW_RST (W1, self-clearing) [11:8] IDLE (2..15, default 3) [12] SDO_NEG [14] TRIG_ACTIVE_LOW
//                       (default 1) [15] SCLK_HALF
//   1 ADC_STATUS  R/W1C [0] RUNNING (RO) [1] BUF0_FULL [2] BUF1_FULL [3] OVERRUN [4] BUS_ERROR [5] DONE [6] WAKE
//                       [8] ACTIVE_BUF (RO)
//   2 ADC_BUF0    RW    byte address of buffer 0, word aligned
//   3 ADC_BUF1    RW    byte address of buffer 1, word aligned
//   4 ADC_NSAMP   RW    samples per buffer, even, 2..1024 (default 128), clamped on write
//   5 ADC_IRQ_EN  RW    [0] BUF_FULL [1] OVERRUN [2] DONE [3] WAKE
//   6 ADC_LAST    RO    most recent sample, sign-extended to 32 bit
//   7 ADC_COUNT   RO    samples taken since RUN was set, saturating at 65535
//   8 ADC_PINS    RW    [0] WAKE_CLR output [1] CAP_EN output (reset 1) [8] WAKE_N input (RO) [9] BIG_N input (RO)
// Points that are not in spec v0.3 (to confirm in the review): STATUS[6] WAKE (the WAKE interrupt needs a flag to
// clear), the 16-bit width of ADC_COUNT, SDO_NEG as one falling-edge flop, and the triggered-mode flags (see below).
//
// Buffers:
//   - free running: buffer 0, then 1, then 0 ... A buffer gets its FULL flag when its last word is written (OBI
//     response received). A buffer that is still FULL when it is due is skipped: OVERRUN is set and its samples are
//     dropped, the buffer keeps its data.
//   - triggered: the buffers are overwritten in turn without FULL flags until the trigger (WAKE_N reaching its active
//     level, or SW_TRIG). The buffer being written then is completed, gets its FULL flag, RUN is cleared and DONE is
//     set when its last word is written. The other buffer also gets its FULL flag if it was completely written at
//     least once, it holds the samples before the trigger.
//   - two words wait in a staging FIFO for the manager port. A word that finds the FIFO full is dropped (OVERRUN).
//   - SW_RST and EN = 0 stop the reader at once. Words already in the staging FIFO are still written.

module adc_rdr #(
  /// OBI request and response types of the manager port (mgr_obi_req_t, mgr_obi_rsp_t)
  parameter type mgr_req_t = logic,
  parameter type mgr_rsp_t = logic
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        testmode_i,

  // register access from obi_spi_regs, already decoded to the ADC block
  input  logic [5:0]  reg_addr_i,  // word offset in the block
  input  logic        reg_wr_i,
  input  logic [31:0] reg_wdata_i,
  input  logic [3:0]  reg_be_i,
  output logic [31:0] reg_rdata_o,

  output mgr_req_t    mgr_req_o,
  input  mgr_rsp_t    mgr_rsp_i,

  output logic        irq_o,

  output logic        sclk_o,
  output logic        csn_o,
  input  logic        sdo_i,
  input  logic        wake_n_i,
  input  logic        big_n_i,
  output logic        wake_clr_o,
  output logic        cap_en_o
);

  // ------------------------------------------------------------------------------------------------ registers
  localparam logic [5:0] RegCtrl = 6'd0, RegStatus = 6'd1, RegBuf0 = 6'd2, RegBuf1 = 6'd3, RegNsamp = 6'd4,
                         RegIrqEn = 6'd5, RegLast = 6'd6, RegCount = 6'd7, RegPins = 6'd8;

  logic        en_q, run_q, trig_mode_q, sdo_neg_q, trig_low_q, half_q;
  logic [3:0]  idle_q;
  logic [1:0]  full_q;
  logic        overrun_q, bus_err_q, done_q, wake_q;
  logic [31:2] buf_q [2];
  logic [10:1] nsamp_q;               // samples per buffer / 2 = words per buffer, 1..512
  logic [3:0]  irq_en_q;
  logic [15:0] last_q, count_q;
  logic        wake_clr_q, cap_en_q;
  logic        active_buf_q, running;
  logic        wake_s, big_s;         // synchronised pad inputs

  logic [31:0] wmask, wmerge;
  assign wmask = {{8{reg_be_i[3]}}, {8{reg_be_i[2]}}, {8{reg_be_i[1]}}, {8{reg_be_i[0]}}};

  // current value of the addressed register, merged with the written bytes
  always_comb begin
    reg_rdata_o = '0;
    unique case (reg_addr_i)
      RegCtrl:   reg_rdata_o = {16'b0, half_q, trig_low_q, 1'b0, sdo_neg_q, idle_q, 5'b0,
                                trig_mode_q, run_q, en_q};
      RegStatus: reg_rdata_o = {23'b0, active_buf_q, 1'b0, wake_q, done_q, bus_err_q, overrun_q, full_q, running};
      RegBuf0:   reg_rdata_o = {buf_q[0], 2'b00};
      RegBuf1:   reg_rdata_o = {buf_q[1], 2'b00};
      RegNsamp:  reg_rdata_o = {21'b0, nsamp_q, 1'b0};
      RegIrqEn:  reg_rdata_o = {28'b0, irq_en_q};
      RegLast:   reg_rdata_o = {{16{last_q[15]}}, last_q};
      RegCount:  reg_rdata_o = {16'b0, count_q};
      RegPins:   reg_rdata_o = {22'b0, big_s, wake_s, 6'b0, cap_en_q, wake_clr_q};
      default:   reg_rdata_o = '0;
    endcase
  end
  assign wmerge = (reg_rdata_o & ~wmask) | (reg_wdata_i & wmask);

  logic wr_ctrl, wr_status;
  assign wr_ctrl   = reg_wr_i && reg_addr_i == RegCtrl;
  assign wr_status = reg_wr_i && reg_addr_i == RegStatus;

  // command pulses (write 1, read 0)
  logic sw_trig, cal_req, sw_rst;
  assign sw_trig = wr_ctrl & wmerge[3];
  assign cal_req = wr_ctrl & wmerge[4];
  assign sw_rst  = wr_ctrl & wmerge[5];

  logic [6:1]  w1c;                   // flag bits written 1 to ADC_STATUS
  assign w1c = wr_status ? (reg_wdata_i[6:1] & wmask[6:1]) : '0;

  logic run_start, run_clear_hw;
  assign run_start = wr_ctrl & wmerge[1] & wmerge[0] & ~run_q & ~sw_rst;

  // ------------------------------------------------------------------------------------------------ pad inputs
  sync #(.STAGES(2), .ResetValue(1'b1)) i_sync_wake (
    .clk_i, .rst_ni, .serial_i ( wake_n_i ), .serial_o ( wake_s ));
  sync #(.STAGES(2), .ResetValue(1'b1)) i_sync_big (
    .clk_i, .rst_ni, .serial_i ( big_n_i  ), .serial_o ( big_s  ));

  logic trig_lvl, trig_lvl_q, wake_evt;
  assign trig_lvl = trig_low_q ? ~wake_s : wake_s;
  assign wake_evt = trig_lvl & ~trig_lvl_q;            // WAKE_N reached its active level

  // ------------------------------------------------------------------------------------------------ frame engine
  typedef enum logic [1:0] { FrNormal, FrCal, FrRecal } frame_e;

  logic        fr_active_q, ph_q;
  logic [6:0]  c_q, len_q;
  logic [3:0]  fidle_q;
  logic        fhalf_q, fneg_q;
  frame_e      ftype_q;
  logic        csn_q, gate_en_q, sclk_half_q;
  logic [13:0] sh_q;                  // D13..D0 (the leading 0 is shifted through and dropped)
  logic        sdo_neg_cap_q;
  logic        cal_pend_q, recal_pend_q, discard_q;
  logic        reset_engine;

  assign reset_engine = ~en_q | sw_rst;

  logic        tick, period_end, work, start_frame;
  logic [6:0]  c_n, c_end, cap_lo, cap_hi, cap_st;
  logic        sdo_s;
  logic        smp_valid;
  logic [15:0] smp;

  assign tick       = fr_active_q & (~fhalf_q | ph_q);
  assign c_end      = len_q + 7'(fidle_q) - 7'd1;
  assign period_end = tick & (c_q == c_end);
  assign work       = cal_pend_q | recal_pend_q | run_q;
  // a frame starts when the engine is idle, or at the end of a period, if there is work
  assign start_frame = en_q & work & (~fr_active_q | period_end);
  assign c_n        = start_frame ? 7'd0 : c_q + 7'd1;

  assign cap_lo = fneg_q ? 7'd2  : 7'd1;
  assign cap_hi = fneg_q ? 7'd16 : 7'd15;
  assign cap_st = fneg_q ? 7'd17 : 7'd16;
  assign sdo_s  = fneg_q ? sdo_neg_cap_q : sdo_i;

  // SDO_NEG: the falling-edge capture flop
  always_ff @(negedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sdo_neg_cap_q <= 1'b0;
    else         sdo_neg_cap_q <= sdo_i;
  end

  logic [6:0] len_next;
  logic [3:0] idle_eff;
  frame_e     ftype_next;
  assign ftype_next = cal_pend_q ? FrCal : (recal_pend_q ? FrRecal : FrNormal);
  assign len_next   = (ftype_next == FrCal) ? 7'd24 : ((ftype_next == FrRecal) ? 7'd64 : 7'd18);
  assign idle_eff   = (idle_q < 4'd2) ? 4'd2 : idle_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fr_active_q <= 1'b0;  ph_q <= 1'b0;  c_q <= '0;  len_q <= 7'd18;  fidle_q <= 4'd3;
      fhalf_q <= 1'b0;  fneg_q <= 1'b0;  ftype_q <= FrNormal;
      csn_q <= 1'b1;  gate_en_q <= 1'b0;  sclk_half_q <= 1'b1;  sh_q <= '0;
      cal_pend_q <= 1'b1;  recal_pend_q <= 1'b0;  discard_q <= 1'b1;
      smp_valid <= 1'b0;  smp <= '0;
    end else begin
      smp_valid <= 1'b0;
      if (cal_req) recal_pend_q <= 1'b1;
      if (reset_engine) begin
        fr_active_q <= 1'b0;  ph_q <= 1'b0;  csn_q <= 1'b1;  gate_en_q <= 1'b0;  sclk_half_q <= 1'b1;
        cal_pend_q  <= 1'b1;  discard_q <= 1'b1;
        if (sw_rst) recal_pend_q <= 1'b0;
      end else if (start_frame) begin
        // state 0 of a new frame: CS falls, configuration taken
        fr_active_q <= 1'b1;  ph_q <= 1'b0;  c_q <= 7'd0;
        ftype_q <= ftype_next;  len_q <= len_next;  fidle_q <= idle_eff;
        fhalf_q <= half_q;  fneg_q <= sdo_neg_q & ~half_q;
        csn_q <= 1'b0;
        gate_en_q <= ~half_q;                         // falling SCLK edge at the start of state 1
        sclk_half_q <= 1'b1;
        if (ftype_next == FrCal)   cal_pend_q   <= 1'b0;
        if (ftype_next == FrRecal) recal_pend_q <= 1'b0;
      end else if (fr_active_q) begin
        if (fhalf_q) ph_q <= ~ph_q;
        if (period_end) begin
          // no more work: CS stays high, the next frame returns a stale sample
          fr_active_q <= 1'b0;  discard_q <= 1'b1;
        end else if (tick) begin
          c_q       <= c_n;
          csn_q     <= ~(c_n <= len_q);
          gate_en_q <= ~fhalf_q & (c_n <= len_q - 7'd1);
          if (fhalf_q) sclk_half_q <= ~(c_n >= 7'd1 && c_n <= len_q);
          if (c_n >= cap_lo && c_n <= cap_hi) sh_q <= {sh_q[12:0], sdo_s};
          if (c_n == cap_st && ftype_q != FrCal) begin
            if (discard_q) discard_q <= 1'b0;
            else begin
              smp_valid <= 1'b1;
              smp       <= {{2{sh_q[13]}}, sh_q[13:0]};
            end
          end
          if (c_n == cap_st && ftype_q == FrCal) discard_q <= 1'b1;
        end else if (fhalf_q) begin
          sclk_half_q <= 1'b1;                        // second half of an SCLK period in SCLK_HALF mode
        end
      end
    end
  end

  assign running = run_q | fr_active_q;

  // SCLK: gated clock, inverted (idles high), or the SCLK_HALF flop, held high in test mode
  logic gclk, sclk_fwd, sclk_sel;
  obi_spi_clk_gate i_sclk_gate (
    .clk_i, .en_i ( gate_en_q ), .test_en_i ( 1'b0 ), .clk_o ( gclk ));
  tc_clk_inverter i_sclk_inv ( .clk_i ( gclk ), .clk_o ( sclk_fwd ));
  tc_clk_mux2 i_sclk_mux ( .clk0_i ( sclk_fwd ), .clk1_i ( sclk_half_q ), .clk_sel_i ( fhalf_q ), .clk_o ( sclk_sel ));
  // (a mux and not tc_clk_or2: the GF180 tech cells have no tc_clk_or2)
  tc_clk_mux2 i_sclk_tm  ( .clk0_i ( sclk_sel ), .clk1_i ( 1'b1 ), .clk_sel_i ( testmode_i ), .clk_o ( sclk_o ));
  assign csn_o = csn_q;

  // ------------------------------------------------------------------------------------------------ sample packer
  typedef struct packed {
    logic        last;                // last word of its buffer
    logic        sel;                 // buffer
    logic        fin;                 // last word of the triggered capture
    logic [31:2] addr;
    logic [31:0] data;
  } stage_t;

  logic        half_have_q;
  logic [15:0] half_smp_q;
  logic [9:0]  widx_q;
  logic        drop_buf_q, trig_seen_q, other_done_q;
  logic        word_valid, word_last;
  stage_t      push_word;
  logic        st_full, st_empty, st_push, st_pop;
  logic        st_usage, if_usage;    // fill levels of the two FIFOs, not used (full and empty are)
  stage_t      st_head;
  logic        set_full_resp;         // last word of a buffer was written (from the response tracker)
  logic        resp_sel, resp_fin;

  assign word_valid = smp_valid & half_have_q & run_q;
  assign word_last  = widx_q == (nsamp_q - 10'd1);
  assign push_word  = '{
    last: word_last,
    sel:  active_buf_q,
    fin:  word_last & trig_mode_q & trig_seen_q,
    addr: buf_q[active_buf_q] + 30'(widx_q),
    data: {smp, half_smp_q}
  };

  // a buffer is skipped when it is still FULL at its first word (free running only)
  logic first_word, skip_word;
  assign first_word = widx_q == '0;
  assign skip_word  = first_word ? (~trig_mode_q & full_q[active_buf_q]) : drop_buf_q;
  assign st_push    = word_valid & ~skip_word & ~st_full;
  assign run_clear_hw = word_valid & word_last & trig_mode_q & trig_seen_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      half_have_q <= 1'b0;  half_smp_q <= '0;  widx_q <= '0;  active_buf_q <= 1'b0;
      drop_buf_q <= 1'b0;  trig_seen_q <= 1'b0;  other_done_q <= 1'b0;
    end else if (sw_rst || run_start) begin
      half_have_q <= 1'b0;  widx_q <= '0;  active_buf_q <= 1'b0;
      drop_buf_q <= 1'b0;  trig_seen_q <= 1'b0;  other_done_q <= 1'b0;
    end else begin
      if (smp_valid && run_q) begin
        half_have_q <= ~half_have_q;
        if (!half_have_q) half_smp_q <= smp;
      end
      if (!run_q) half_have_q <= 1'b0;
      if (trig_mode_q && run_q && !trig_seen_q && (wake_evt || sw_trig)) trig_seen_q <= 1'b1;
      if (word_valid) begin
        if (first_word) drop_buf_q <= ~trig_mode_q & full_q[active_buf_q];
        if (word_last) begin
          widx_q       <= '0;
          active_buf_q <= ~active_buf_q;
          if (trig_mode_q && !trig_seen_q) other_done_q <= 1'b1;
        end else begin
          widx_q <= widx_q + 10'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------------------------------------------ manager port
  fifo_v3 #(
    .FALL_THROUGH ( 1'b0    ),
    .DEPTH        ( 2       ),
    .dtype        ( stage_t )
  ) i_stage (
    .clk_i,
    .rst_ni,
    .flush_i    ( 1'b0      ),
    .testmode_i,
    .full_o     ( st_full   ),
    .empty_o    ( st_empty  ),
    .usage_o    ( st_usage  ),
    .data_i     ( push_word ),
    .push_i     ( st_push   ),
    .data_o     ( st_head   ),
    .pop_i      ( st_pop    )
  );

  // words granted and waiting for their response, in order
  typedef struct packed { logic last; logic sel; logic fin; } inflight_t;
  logic      if_full, if_empty;
  inflight_t if_head, if_push;
  assign if_push = '{last: st_head.last, sel: st_head.sel, fin: st_head.fin};

  always_comb begin
    mgr_req_o         = '0;
    mgr_req_o.req     = ~st_empty & ~if_full;
    mgr_req_o.a.addr  = {st_head.addr, 2'b00};
    mgr_req_o.a.we    = 1'b1;
    mgr_req_o.a.be    = 4'hF;
    mgr_req_o.a.wdata = st_head.data;
    mgr_req_o.a.aid   = '0;
  end
  assign st_pop = mgr_req_o.req & mgr_rsp_i.gnt;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0       ),
    .DEPTH        ( 2          ),
    .dtype        ( inflight_t )
  ) i_inflight (
    .clk_i,
    .rst_ni,
    .flush_i    ( 1'b0         ),
    .testmode_i,
    .full_o     ( if_full      ),
    .empty_o    ( if_empty     ),
    .usage_o    ( if_usage     ),
    .data_i     ( if_push      ),
    .push_i     ( st_pop       ),
    .data_o     ( if_head      ),
    .pop_i      ( mgr_rsp_i.rvalid & ~if_empty )
  );

  assign set_full_resp = mgr_rsp_i.rvalid & ~if_empty & if_head.last & (~trig_mode_q | if_head.fin);
  assign resp_sel      = if_head.sel;
  assign resp_fin      = mgr_rsp_i.rvalid & ~if_empty & if_head.fin;

  // ------------------------------------------------------------------------------------------------ register state
  logic [15:0] nsamp_w;
  assign nsamp_w = wmerge[15:0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      en_q <= 1'b0;  run_q <= 1'b0;  trig_mode_q <= 1'b0;  idle_q <= 4'd3;  sdo_neg_q <= 1'b0;
      trig_low_q <= 1'b1;  half_q <= 1'b0;
      full_q <= '0;  overrun_q <= 1'b0;  bus_err_q <= 1'b0;  done_q <= 1'b0;  wake_q <= 1'b0;
      buf_q[0] <= '0;  buf_q[1] <= '0;  nsamp_q <= 10'd64;  irq_en_q <= '0;
      last_q <= '0;  count_q <= '0;  wake_clr_q <= 1'b0;  cap_en_q <= 1'b1;  trig_lvl_q <= 1'b0;
    end else begin
      trig_lvl_q <= trig_lvl;

      // ADC_CTRL
      if (wr_ctrl) begin
        en_q        <= wmerge[0];
        run_q       <= wmerge[1] & wmerge[0] & ~sw_rst;
        trig_mode_q <= wmerge[2];
        idle_q      <= (wmerge[11:8] < 4'd2) ? 4'd2 : wmerge[11:8];
        sdo_neg_q   <= wmerge[12];
        trig_low_q  <= wmerge[14];
        half_q      <= wmerge[15];
      end
      if (run_clear_hw) run_q <= 1'b0;

      // ADC_STATUS: hardware set wins over a clear in the same cycle
      full_q    <= full_q & ~w1c[2:1];
      overrun_q <= overrun_q & ~w1c[3];
      bus_err_q <= bus_err_q & ~w1c[4];
      done_q    <= done_q & ~w1c[5];
      wake_q    <= wake_q & ~w1c[6];
      if (sw_rst) begin
        full_q <= '0;  overrun_q <= 1'b0;  bus_err_q <= 1'b0;  done_q <= 1'b0;  wake_q <= 1'b0;
      end
      if (set_full_resp) full_q[resp_sel] <= 1'b1;
      // last word of a triggered capture dropped (staging FIFO full): the capture still ends
      if (run_clear_hw && !st_push) done_q <= 1'b1;
      if (resp_fin) begin
        done_q <= 1'b1;
        if (other_done_q) full_q[~resp_sel] <= 1'b1;
      end
      if (word_valid && ((first_word && ~trig_mode_q && full_q[active_buf_q]) || st_full)) overrun_q <= 1'b1;
      if (mgr_rsp_i.rvalid && mgr_rsp_i.r.err) bus_err_q <= 1'b1;
      if (wake_evt) wake_q <= 1'b1;

      // buffers, sample count, irq enables, pins
      if (reg_wr_i && reg_addr_i == RegBuf0) buf_q[0] <= wmerge[31:2];
      if (reg_wr_i && reg_addr_i == RegBuf1) buf_q[1] <= wmerge[31:2];
      if (reg_wr_i && reg_addr_i == RegNsamp)
        nsamp_q <= (nsamp_w < 16'd2) ? 10'd1 : ((nsamp_w > 16'd1024) ? 10'd512 : nsamp_w[10:1]);
      if (reg_wr_i && reg_addr_i == RegIrqEn) irq_en_q <= wmerge[3:0];
      if (reg_wr_i && reg_addr_i == RegPins) begin
        wake_clr_q <= wmerge[0];
        cap_en_q   <= wmerge[1];
      end

      if (smp_valid) last_q <= smp;
      if (run_start) count_q <= '0;
      else if (smp_valid && run_q && count_q != 16'hFFFF) count_q <= count_q + 16'd1;
    end
  end

  // ADC_IRQ_EN: [0] BUF_FULL [1] OVERRUN [2] DONE [3] WAKE
  assign irq_o      = |({wake_q, done_q, overrun_q, |full_q} & irq_en_q);

  logic unused;
  assign unused = ^{st_usage, if_usage};
  assign wake_clr_o = wake_clr_q;
  assign cap_en_o   = cap_en_q;

endmodule
