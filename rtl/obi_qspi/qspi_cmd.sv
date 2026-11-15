// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// Command engine of the QSPI bus (flash on CS0, PSRAM on CS1 and CS2), at 0x2200_2000 (user_pkg::UserQCmdAddrBase).
// obi_qspi reads and writes the devices as memory with two commands only (read 0x03 / 0xEB, write 0x02 / 0x38).
// This block sends any other command: write enable, erase, status registers, the QE bit, JEDEC ID, reset, power
// down. Every command is a byte sequence (opcode, address bytes, dummy bytes, data), sent by an rf_spi master
// (byte oriented, full duplex, 8-byte FIFOs with flow control, up to 4095 bytes with CS low, KEEP_CS) on single
// lines: SCLK, SIO0 = MOSI, SIO1 = MISO. SIO2 (WP#) and SIO3 (HOLD# / RESET#) are driven high during a command.
// Use SPI mode 0 (CPOL = CPHA = 0) or mode 3. CLKDIV = 1 gives SCLK = f_clk / 4.
//
// Bus sharing with obi_qspi: a command takes the bus between memory accesses. From RF_CMD until its CS rises (KEEP_CS
// keeps it), obi_qspi grants no access, and a memory access in progress ends first. Code that sends commands to the
// flash must therefore not run from the flash (it would wait for itself): run it from the SRAM.
//
// Register map (word offsets, byte offsets 0x000 + 4 x word):
//   0..7  the registers of rf_spi.sv: 0 CTRL, 1 STATUS, 2 CMD, 3 DATA, 4 IRQ_EN, 5 IRQ_STATUS, 6 PINS (unused),
//         7 ERR. CTRL[0] EN must be set.
//   8     QCTRL RW  [1:0] CS: the device of the commands (0 flash CS0, 1 PSRAM0 CS1, 2 PSRAM1 CS2, 3 none)
//                   [4] PSRAM0_QUAD [5] PSRAM1_QUAD: obi_qspi reads and writes that PSRAM in quad (0xEB with 6 wait
//                   clocks, 0x38). The flash stays single (qqspi's quad protocol does not fit the W25Q).
// An access at word 9 or above gets an OBI error.
//
// Examples (W25Q128JV flash on CS0, see sim/sw/qspi_cmd/qspi_cmd_test.c):
//   JEDEC ID:      9F, read 3 bytes -> EF 40 18
//   sector erase:  06 (write enable), then 20 A23..A0, then 05 (read status 1) until bit 0 (BUSY) is 0
//   page program:  06, then 02 A23..A0 D0..Dn (at most 256 bytes, inside one page), then 05 until BUSY is 0
//   QE bit:        06, then 31 02 (write status 2, QE = 1), then 05 until BUSY is 0. 35 reads status 2.
`include "common_cells/registers.svh"
module qspi_cmd #(
  /// The OBI configuration connected to this peripheral (SbrObiCfg)
  parameter obi_pkg::obi_cfg_t ObiCfg = obi_pkg::ObiDefaultConfig,
  /// OBI request type
  parameter type obi_req_t = logic,
  /// OBI response type
  parameter type obi_rsp_t = logic
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       testmode_i,

  input  obi_req_t   obi_req_i,
  output obi_rsp_t   obi_rsp_o,

  output logic       irq_o,

  // bus sharing with obi_qspi
  output logic       bus_req_o,   // obi_qspi grants no memory access while it is high
  input  logic       bus_gnt_i,   // obi_qspi is idle: the command may start
  output logic [1:0] psram_quad_o,

  // command pins, muxed onto the QSPI pads by user_domain while bus_gnt_i is high
  output logic       sclk_o,
  output logic       mosi_o,
  input  logic       miso_i,
  output logic [2:0] csn_o
);
  localparam int unsigned NumRegs = 9;

  // OBI front end: every request is one register access, answered in the next cycle (as obi_spi_regs.sv)
  logic [3:0]                  addr;
  logic                        mapped, wr, rd;
  logic                        valid_q, err_q;
  logic [ObiCfg.IdWidth-1:0]   id_q;
  logic [ObiCfg.DataWidth-1:0] rdata, rdata_q, spi_rdata;

  assign addr   = obi_req_i.a.addr[5:2];
  assign mapped = obi_req_i.a.addr[11:2] < NumRegs;
  assign wr     = obi_req_i.req &  obi_req_i.a.we & mapped;
  assign rd     = obi_req_i.req & ~obi_req_i.a.we & mapped;

  `FF(valid_q, obi_req_i.req, 1'b0, clk_i, rst_ni)
  `FFL(id_q,    obi_req_i.a.aid,          obi_req_i.req, '0,   clk_i, rst_ni)
  `FFL(err_q,   ~mapped,                  obi_req_i.req, 1'b0, clk_i, rst_ni)
  `FFL(rdata_q, (rd ? rdata : '0),        obi_req_i.req, '0,   clk_i, rst_ni)

  always_comb begin
    obi_rsp_o         = '0;
    obi_rsp_o.gnt     = obi_req_i.req;
    obi_rsp_o.rvalid  = valid_q;
    obi_rsp_o.r.rid   = id_q;
    obi_rsp_o.r.err   = err_q;
    obi_rsp_o.r.rdata = rdata_q;
  end

  // QCTRL
  logic [1:0] cs_q;
  logic [1:0] quad_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cs_q   <= 2'd0;
      quad_q <= 2'b00;
    end else if (wr && addr == 4'd8 && obi_req_i.a.be[0]) begin
      cs_q   <= obi_req_i.a.wdata[1:0];
      quad_q <= obi_req_i.a.wdata[5:4];
    end
  end
  assign psram_quad_o = quad_q;
  assign rdata = (addr == 4'd8) ? {26'b0, quad_q, 2'b00, cs_q} : spi_rdata;

  // SPI master (the radio master of the SPI block)
  logic csn, rstn_unused, rf_req;
  rf_spi i_spi (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .reg_addr_i  ( {2'b0, addr}             ),
    .reg_wr_i    ( wr && addr < 4'd8        ),
    .reg_rd_i    ( rd && addr < 4'd8        ),
    .reg_wdata_i ( obi_req_i.a.wdata        ),
    .reg_be_i    ( obi_req_i.a.be           ),
    .reg_rdata_o ( spi_rdata                ),
    .irq_o,
    .bus_req_o   ( rf_req                   ),
    .bus_gnt_i,
    .sclk_o,
    .mosi_o,
    .miso_i,
    .csn_o       ( csn                      ),
    .dio0_i      ( 1'b0                     ),
    .rstn_o      ( rstn_unused              )
  );

  // The bus request stays high 2 clocks after rf_spi drops it. rf_spi drops it in the cycle that CS rises, and then
  // user_domain gives SCLK back to obi_qspi, whose idle SCLK is 1: in mode 0 that was a rising SCLK edge at the CS
  // rise, and the W25Q dropped every command it runs at the CS rise (ZedBoard, 9 Nov 2026). With the hold, the
  // switch comes 2 clocks after CS is high, where the devices ignore SCLK.
  logic [1:0] req_hold_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) req_hold_q <= 2'b00;
    else         req_hold_q <= {req_hold_q[0], rf_req};
  end
  assign bus_req_o = rf_req | (|req_hold_q);

  // the chip select of the device selected in QCTRL
  always_comb begin
    csn_o = 3'b111;
    if (cs_q != 2'd3) csn_o[cs_q] = csn;
  end
endmodule
