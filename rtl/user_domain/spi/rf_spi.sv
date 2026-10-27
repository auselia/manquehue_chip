// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Radio SPI master of the SPI block (docs/spi_adc_spec.md section 4), for the SX1276 (RFM9x, LoRa).
// SPI modes 0 to 3, MSB first, byte oriented, full duplex. Software pushes the TX bytes, writes RF_CMD with the
// number of bytes, and every shifted byte puts one byte into the RX FIFO.
//
// Timing: one SCLK half period is CLKDIV + 1 clocks (SCLK = f_clk / (2 x (CLKDIV + 1))). CS falls CS_SETUP half
// periods (at least one) before the first SCLK edge and rises CS_SETUP half periods after the last one, unless
// KEEP_CS. MISO is sampled by clk_i at the clock edge that makes the SCLK sampling edge: half an SCLK period after
// the radio launched it.
// Shared bus: the radio shares SCLK and the data lines with the ADS7057 reader (obi_spi). A command first waits in
// StWait, with CS high and SCLK at CPOL, until obi_spi grants the bus (bus_gnt_i). The master requests the bus from
// the command until CS rises again, so KEEP_CS keeps the bus. BUSY covers the wait.
// Flow control: before each byte the master waits with SCLK idle and CS low while the TX FIFO is empty or the RX FIFO
// is full, so a transfer longer than the 8-byte FIFOs loses nothing (the 256-byte radio FIFO included).
//
// Register map (word offsets of the radio block, byte offsets 0x000 + 4 x word):
//   0 RF_CTRL       RW    [0] EN [1] SW_RST (W1, self-clearing, flushes both FIFOs) [2] CPOL [3] CPHA
//                         [15:8] CLKDIV [19:16] CS_SETUP
//   1 RF_STATUS     RO    [0] BUSY [1] TX_EMPTY [2] TX_FULL [3] RX_EMPTY [4] RX_FULL [15:8] TX_LEVEL [23:16] RX_LEVEL
//   2 RF_CMD        WO    [11:0] NBYTES (1 to 4095) [12] KEEP_CS. Ignored while BUSY or EN = 0.
//   3 RF_DATA       RW    write: push the byte of the lowest enabled byte lane. read: pop one RX byte, bits [7:0]
//   4 RF_IRQ_EN     RW    [0] DONE [1] TX_EMPTY [2] RX_AVAIL [3] ERROR [4] DIO0
//   5 RF_IRQ_STATUS R/W1C [0] DONE (sticky) [1] TX_EMPTY (level) [2] RX_AVAIL (level) [3] ERROR (any RF_ERR bit,
//                         W1C clears RF_ERR) [4] DIO0 rising edge (sticky)
//   6 RF_PINS       RW    [0] RSTN output (reset 0: radio in reset) [8] DIO0 input level (RO)
//   7 RF_ERR        R/W1C [0] TX_OVERFLOW (push to a full TX FIFO, byte dropped) [1] RX_OVERRUN (cannot happen: the
//                         master waits on a full RX FIFO, kept for the register map) [2] RX_UNDERFLOW (read of an
//                         empty RX FIFO, returns the last byte)

module rf_spi (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        testmode_i,

  // register access from obi_spi_regs, already decoded to the radio block
  input  logic [5:0]  reg_addr_i,  // word offset in the block
  input  logic        reg_wr_i,
  input  logic        reg_rd_i,
  input  logic [31:0] reg_wdata_i,
  input  logic [3:0]  reg_be_i,
  output logic [31:0] reg_rdata_o,

  output logic        irq_o,

  // shared SPI bus (obi_spi)
  output logic        bus_req_o,
  input  logic        bus_gnt_i,

  output logic        sclk_o,
  output logic        mosi_o,
  input  logic        miso_i,
  output logic        csn_o,
  input  logic        dio0_i,
  output logic        rstn_o
);

  localparam logic [5:0] RegCtrl = 6'd0, RegStatus = 6'd1, RegCmd = 6'd2, RegData = 6'd3, RegIrqEn = 6'd4,
                         RegIrqSt = 6'd5, RegPins = 6'd6, RegErr = 6'd7;

  // ------------------------------------------------------------------------------------------------ registers
  logic        en_q, cpol_q, cpha_q;
  logic [7:0]  clkdiv_q;
  logic [3:0]  cs_setup_q;
  logic [4:0]  irq_en_q;
  logic        rstn_q, done_q, dio0_flag_q;
  logic [2:0]  err_q;                 // TX_OVERFLOW, RX_OVERRUN, RX_UNDERFLOW
  logic [7:0]  last_rx_q;
  logic        dio0_s, dio0_s_q;
  logic        busy;

  logic        tx_full, tx_empty, rx_full, rx_empty;
  logic [2:0]  tx_usage, rx_usage;
  logic [3:0]  tx_level, rx_level;
  logic [7:0]  tx_head, rx_head;
  assign tx_level = tx_full ? 4'd8 : {1'b0, tx_usage};
  assign rx_level = rx_full ? 4'd8 : {1'b0, rx_usage};

  logic [4:0] irq_status;
  assign irq_status = {dio0_flag_q, |err_q, ~rx_empty, tx_empty, done_q};

  always_comb begin
    reg_rdata_o = '0;
    unique case (reg_addr_i)
      RegCtrl:   reg_rdata_o = {12'b0, cs_setup_q, clkdiv_q, 4'b0, cpha_q, cpol_q, 1'b0, en_q};
      RegStatus: reg_rdata_o = {8'b0, 4'b0, rx_level, 4'b0, tx_level, 3'b0, rx_full, rx_empty, tx_full, tx_empty, busy};
      RegData:   reg_rdata_o = {24'b0, rx_empty ? last_rx_q : rx_head};
      RegIrqEn:  reg_rdata_o = {27'b0, irq_en_q};
      RegIrqSt:  reg_rdata_o = {27'b0, irq_status};
      RegPins:   reg_rdata_o = {23'b0, dio0_s, 7'b0, rstn_q};
      RegErr:    reg_rdata_o = {29'b0, err_q};
      default:   reg_rdata_o = '0;
    endcase
  end

  logic [31:0] wmask, wmerge;
  assign wmask  = {{8{reg_be_i[3]}}, {8{reg_be_i[2]}}, {8{reg_be_i[1]}}, {8{reg_be_i[0]}}};
  assign wmerge = (reg_rdata_o & ~wmask) | (reg_wdata_i & wmask);

  logic wr_ctrl, wr_cmd, wr_data, rd_data, sw_rst;
  assign wr_ctrl = reg_wr_i && reg_addr_i == RegCtrl;
  assign wr_cmd  = reg_wr_i && reg_addr_i == RegCmd;
  assign wr_data = reg_wr_i && reg_addr_i == RegData;
  assign rd_data = reg_rd_i && reg_addr_i == RegData;
  assign sw_rst  = wr_ctrl & wmerge[1];

  // byte of the lowest enabled lane for RF_DATA
  logic [7:0] wr_byte;
  always_comb begin
    if      (reg_be_i[0]) wr_byte = reg_wdata_i[7:0];
    else if (reg_be_i[1]) wr_byte = reg_wdata_i[15:8];
    else if (reg_be_i[2]) wr_byte = reg_wdata_i[23:16];
    else                  wr_byte = reg_wdata_i[31:24];
  end

  // RF_CMD as written (the whole register, byte enables applied to a zero register)
  logic [31:0] cmd_w;
  assign cmd_w = reg_wdata_i & wmask;
  logic start;
  assign start = wr_cmd & en_q & ~busy & ~sw_rst & (cmd_w[11:0] != 12'd0);

  // ------------------------------------------------------------------------------------------------ FIFOs
  logic tx_push, tx_pop, rx_push, rx_pop;
  logic [7:0] rx_byte;
  assign tx_push = wr_data & ~tx_full;
  assign rx_pop  = rd_data & ~rx_empty;

  fifo_v3 #(.FALL_THROUGH(1'b0), .DATA_WIDTH(8), .DEPTH(8)) i_tx_fifo (
    .clk_i, .rst_ni, .flush_i(sw_rst), .testmode_i,
    .full_o(tx_full), .empty_o(tx_empty), .usage_o(tx_usage),
    .data_i(wr_byte), .push_i(tx_push), .data_o(tx_head), .pop_i(tx_pop));

  fifo_v3 #(.FALL_THROUGH(1'b0), .DATA_WIDTH(8), .DEPTH(8)) i_rx_fifo (
    .clk_i, .rst_ni, .flush_i(sw_rst), .testmode_i,
    .full_o(rx_full), .empty_o(rx_empty), .usage_o(rx_usage),
    .data_i(rx_byte), .push_i(rx_push), .data_o(rx_head), .pop_i(rx_pop));

  sync #(.STAGES(2), .ResetValue(1'b0)) i_sync_dio0 (
    .clk_i, .rst_ni, .serial_i(dio0_i), .serial_o(dio0_s));

  // ------------------------------------------------------------------------------------------------ transfer engine
  typedef enum logic [2:0] { StIdle, StWait, StSetup, StByte, StHold } state_e;
  state_e      state_q;
  logic [11:0] left_q;                // bytes still to shift, the current one included
  logic        keep_q;
  logic [7:0]  div_q;
  logic [3:0]  half_q;                // half periods counted in StSetup and StHold
  logic [3:0]  edge_q;                // SCLK edges of the current byte, 0 to 15
  logic        need_byte_q;           // the next byte is not yet taken from the TX FIFO
  logic [7:0]  sh_out_q, sh_in_q;
  logic        sclk_q, mosi_q, csn_q;
  logic        tick;
  logic [3:0]  cs_half;

  assign cs_half = (cs_setup_q == 4'd0) ? 4'd1 : cs_setup_q;
  assign busy    = state_q != StIdle;
  // A timed phase runs in StSetup, StHold and between the edges of a byte. Before each byte the engine takes the
  // next TX byte, and waits (SCLK idle, divider held) while the TX FIFO is empty or the RX FIFO is full.
  logic running;
  assign running = busy & (state_q != StWait) & ~((state_q == StByte) & need_byte_q);
  assign tick    = running & (div_q == clkdiv_q);
  assign tx_pop  = (state_q == StByte) & need_byte_q & ~tx_empty & ~rx_full;

  logic last_edge, leading;
  assign leading   = ~edge_q[0];
  assign last_edge = (state_q == StByte) & ~need_byte_q & tick & (edge_q == 4'd15);
  // the received byte, with the sample of this edge when the last bit is taken at the last (trailing) edge
  assign rx_byte   = cpha_q ? {sh_in_q[6:0], miso_i} : sh_in_q;
  assign rx_push   = last_edge;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StIdle;  left_q <= '0;  keep_q <= 1'b0;  div_q <= '0;  half_q <= '0;  edge_q <= '0;
      need_byte_q <= 1'b1;  sh_out_q <= '0;  sh_in_q <= '0;  sclk_q <= 1'b0;  mosi_q <= 1'b0;  csn_q <= 1'b1;
    end else if (sw_rst || !en_q) begin
      state_q <= StIdle;  keep_q <= 1'b0;  div_q <= '0;  half_q <= '0;  edge_q <= '0;  need_byte_q <= 1'b1;
      sclk_q <= cpol_q;  mosi_q <= 1'b0;  csn_q <= 1'b1;
    end else begin
      // divider: counts while a timed phase runs, restarts at every tick
      if (!running || tick) div_q <= '0;
      else                  div_q <= div_q + 8'd1;

      unique case (state_q)
        StIdle: begin
          sclk_q <= cpol_q;
          if (start) begin
            state_q <= StWait;  left_q <= cmd_w[11:0];  keep_q <= cmd_w[12];  mosi_q <= 1'b0;
          end
        end
        StWait: if (bus_gnt_i) begin
          state_q <= StSetup;  half_q <= '0;  csn_q <= 1'b0;
        end
        StSetup: if (tick) begin
          if (half_q == cs_half - 4'd1) begin state_q <= StByte; need_byte_q <= 1'b1; end
          else half_q <= half_q + 4'd1;
        end
        StByte: begin
          if (tx_pop) begin
            // take the next byte: with CPHA 0 the first bit is on MOSI before the first edge
            sh_out_q    <= tx_head;
            need_byte_q <= 1'b0;
            edge_q      <= '0;
            if (!cpha_q) mosi_q <= tx_head[7];
          end else if (tick) begin
            sclk_q <= ~sclk_q;
            if (leading == ~cpha_q) sh_in_q <= {sh_in_q[6:0], miso_i};        // sampling edge
            else if (cpha_q) begin                                          // CPHA 1: shift at the leading edge
              mosi_q   <= sh_out_q[7];
              sh_out_q <= {sh_out_q[6:0], 1'b0};
            end else if (edge_q != 4'd15) begin                             // CPHA 0: next bit at the trailing edge
              mosi_q   <= sh_out_q[6];
              sh_out_q <= {sh_out_q[6:0], 1'b0};
            end
            edge_q <= edge_q + 4'd1;
            if (edge_q == 4'd15) begin
              need_byte_q <= 1'b1;
              left_q      <= left_q - 12'd1;
              if (left_q == 12'd1) begin state_q <= StHold; half_q <= '0; end
            end
          end
        end
        StHold: if (tick) begin
          if (half_q == cs_half - 4'd1) begin
            state_q <= StIdle;
            mosi_q  <= 1'b0;
            if (!keep_q) csn_q <= 1'b1;
          end else half_q <= half_q + 4'd1;
        end
        default: state_q <= StIdle;
      endcase
    end
  end

  // ------------------------------------------------------------------------------------------------ register state
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      en_q <= 1'b0;  cpol_q <= 1'b0;  cpha_q <= 1'b0;  clkdiv_q <= 8'd24;  cs_setup_q <= 4'd1;
      irq_en_q <= '0;  rstn_q <= 1'b0;  done_q <= 1'b0;  dio0_flag_q <= 1'b0;  err_q <= '0;  last_rx_q <= '0;
      dio0_s_q <= 1'b0;
    end else begin
      dio0_s_q <= dio0_s;
      if (wr_ctrl) begin
        en_q       <= wmerge[0];
        if (!busy) begin                                   // mode and speed change only between transfers
          cpol_q     <= wmerge[2];
          cpha_q     <= wmerge[3];
          clkdiv_q   <= wmerge[15:8];
          cs_setup_q <= wmerge[19:16];
        end
      end
      if (reg_wr_i && reg_addr_i == RegIrqEn) irq_en_q <= wmerge[4:0];
      if (reg_wr_i && reg_addr_i == RegPins)  rstn_q   <= wmerge[0];

      // sticky flags: write 1 to clear, a new event in the same cycle wins
      if (reg_wr_i && reg_addr_i == RegIrqSt) begin
        if (reg_wdata_i[0] & reg_be_i[0]) done_q      <= 1'b0;
        if (reg_wdata_i[3] & reg_be_i[0]) err_q       <= '0;
        if (reg_wdata_i[4] & reg_be_i[0]) dio0_flag_q <= 1'b0;
      end
      if (reg_wr_i && reg_addr_i == RegErr) err_q <= err_q & ~(reg_wdata_i[2:0] & {3{reg_be_i[0]}});
      if (sw_rst) begin done_q <= 1'b0; err_q <= '0; end

      if (state_q == StHold && tick && half_q == cs_half - 4'd1) done_q <= 1'b1;
      if (wr_data && tx_full)  err_q[0] <= 1'b1;
      if (rd_data && rx_empty) err_q[2] <= 1'b1;
      if (rx_pop) last_rx_q <= rx_head;
      if (dio0_s && !dio0_s_q) dio0_flag_q <= 1'b1;
    end
  end

  assign irq_o  = |(irq_status & irq_en_q);
  assign sclk_o = en_q ? sclk_q : cpol_q;
  assign mosi_o = en_q ? mosi_q : 1'b0;
  assign csn_o  = en_q ? csn_q : 1'b1;
  assign rstn_o = rstn_q;
  assign bus_req_o = en_q & (busy | ~csn_q);

  // register bits without a field
  logic unused;
  assign unused = ^{wmerge[31:20], wmerge[7:5], cmd_w[31:13]};

endmodule
