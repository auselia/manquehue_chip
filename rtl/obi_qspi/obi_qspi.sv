// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// OBI <-> qqspi wrapper
// ---------------------
// Memory-mapped bridge between the Croc user_domain OBI subordinate bus and the
// `qqspi` SPI/QSPI PSRAM+flash controller. Presents a single 32 MB window that is
// transparently backed by three physical devices sharing one SPI bus:
//
//   window-relative byte address       size   device   ce_ctrl   PSRAM_SPIFLASH
//   0x000_0000 .. 0x0FF_FFFF           16 MB   Flash    3'b001    0  (flash mode)
//   0x100_0000 .. 0x17F_FFFF            8 MB   PSRAM0   3'b010    1  (psram mode)
//   0x180_0000 .. 0x1FF_FFFF            8 MB   PSRAM1   3'b100    1  (psram mode)
//
// The bank-select bits addr[24:23] pick the chip-select / mode; the full word
// index addr[24:2] is handed to qqspi unchanged. qqspi internally masks it to
// addr[21:0] (flash, 16 MB) or addr[20:0] (psram, 8 MB), so the bank bits never
// leak into the SPI address frame and no per-bank offset subtraction is needed.
//
// Notes / caveats:
//  * DataWidth is assumed to be 32; the qqspi core is fixed 32-bit.
//  * The window base must be 32 MB-aligned so that addr[24:0] is the offset.
//  * Quad mode is decoded per-bank (see *Quad localparams) and defaults to
//    single-SPI on every device for bring-up. qqspi uses a FIXED 6-cycle quad
//    read dummy phase for all devices, so mixed dummy-cycle requirements would
//    need a change inside qqspi itself, not here.
//  * A store into the flash bank issues command 0x02 (page program), which on a
//    real flash needs erase + write-enable first. Those, and every other command
//    (status, QE, JEDEC ID, reset, power down), go through qspi_cmd (0x2200_2000),
//    which shares the pins: while cmd_req_i is high no access is granted here, and
//    cmd_gnt_o tells qspi_cmd that the bus is free (no access in progress).
//  * PSRAM quad mode is set at run time (psram_quad_i, from qspi_cmd QCTRL).
//  * SPI pins are exposed as buses and left unrouted here; wire them out through
//    user_domain / croc_soc to the pad ring.

`include "common_cells/registers.svh"

module obi_qspi #(
  /// The OBI configuration connected to this peripheral (= SbrObiCfg).
  parameter obi_pkg::obi_cfg_t ObiCfg = obi_pkg::ObiDefaultConfig,
  /// OBI request type  (= sbr_obi_req_t).
  parameter type obi_req_t = logic,
  /// OBI response type (= sbr_obi_rsp_t).
  parameter type obi_rsp_t = logic,
  /// Number of physical chip-selects driven by qqspi (must be 3 for this map).
  parameter int unsigned NumCs = 3,
  parameter logic [31:0] WindowBase = 32'h2100_0000
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     testmode_i, // unused, kept for drop-in compatibility

  // OBI request interface
  input  obi_req_t obi_req_i,   // a.addr, a.we, a.be, a.wdata, a.aid | req, rready
  // OBI response interface
  output obi_rsp_t obi_rsp_o,   // r.rdata, r.rid, r.err | gnt, rvalid

  // -- SPI pad interface (unrouted for now) ------------------------------------
  output logic             spi_clk_o,    // sclk
  output logic [3:0]       spi_sd_o,     // sio[3:0] output value  {sio3,sio2,sio1,sio0}
  input  logic [3:0]       spi_sd_i,     // sio[3:0] input value
  output logic [3:0]       spi_sd_en_o,  // sio[3:0] output enable (sio_oe)
  output logic [NumCs-1:0] spi_csn_o,    // active-low chip selects (ce)

  // -- bus sharing with qspi_cmd and run-time PSRAM quad mode -----------------
  input  logic             cmd_req_i,    // qspi_cmd wants the bus: grant no new access
  output logic             cmd_gnt_o,    // no access in progress: qspi_cmd owns the pins
  input  logic [1:0]       psram_quad_i  // [0] PSRAM0, [1] PSRAM1 in quad mode
);

  // Silence unused-signal lint; testmode is not needed by this peripheral.
  logic unused_testmode;
  assign unused_testmode = testmode_i;

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Address map / per-bank configuration                                                       //
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Chip-select one-hot codes fed to qqspi.ce_ctrl (qqspi drives ce = ~ce_ctrl).
  localparam logic [NumCs-1:0] CeFlash  = 3'b001; // CS0
  localparam logic [NumCs-1:0] CePsram0 = 3'b010; // CS1
  localparam logic [NumCs-1:0] CePsram1 = 3'b100; // CS2

  // Per-bank quad-mode enable. The PSRAM entries are set at run time (psram_quad_i).
  //
  // PSRAM (APS6404L): quad is safe. Its 0xEB Fast-Read-Quad uses a 6-cycle dummy and
  //   no mode byte, which is exactly what the qqspi core emits (S5_WAIT = 6, address-
  //   only), and 0x38 is a valid quad-write. Psram0Quad/Psram1Quad = 1'b1 is fine.
  //
  // FLASH (W25Q128JV): DO NOT enable quad here. The qqspi core is incompatible with
  //   this part's quad protocol in three ways, so FlashQuad = 1'b1 yields corrupt reads
  //   and a wrong write:
  //     1. 0xEB on the W25Q requires a mode byte M7-M0 after the address; qqspi sends none.
  //     2. 0xEB on the W25Q needs a different dummy count; qqspi's dummy phase is fixed at 6.
  //     3. Quad reads need the QE bit set in Status-Register-2; qqspi cannot issue that,
  //        and 0x38 (qqspi's quad-write opcode) is "Enter QPI" on the W25Q, not a write
  //        (its quad page-program is 0x32).
  //   Enabling flash quad requires changes inside the qqspi core, not this wrapper, so
  //   FlashQuad is guarded to 0 by the assertion below.
  localparam logic FlashQuad  = 1'b0;
  logic Psram0Quad, Psram1Quad;
  assign Psram0Quad = psram_quad_i[0];
  assign Psram1Quad = psram_quad_i[1];

  // Elaboration-time guard: quad on the flash bank is unsupported by the qqspi core.
  // This fails the build (not just simulation) if someone flips FlashQuad to 1'b1.
  if (FlashQuad != 1'b0) begin : gen_flash_quad_unsupported
    $fatal(1, "obi_qspi: FlashQuad must be 1'b0 - qqspi's quad protocol is incompatible with the W25Q flash (missing M7-M0 mode byte, fixed 6-cycle dummy, no QE set, and 0x38 = Enter-QPI not write). See the comment above FlashQuad.");
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Bank decode of the incoming request address                                                //
  ////////////////////////////////////////////////////////////////////////////////////////////////

  // Window-relative byte address (window is 32 MB-aligned => low 25 bits = offset).
  logic [24:0] dec_addr;
  assign dec_addr = 25'(obi_req_i.a.addr - WindowBase);

  logic [NumCs-1:0] ce_ctrl_dec;
  logic             psram_dec;
  logic             quad_dec;
  logic             bad_dec;

  always_comb begin
    ce_ctrl_dec = '0;
    psram_dec   = 1'b0;
    quad_dec    = 1'b0;
    bad_dec     = 1'b0;
    casez (dec_addr[24:23])
      2'b0?:   begin ce_ctrl_dec = CeFlash;  psram_dec = 1'b0; quad_dec = FlashQuad;  end // Flash  16 MB
      2'b10:   begin ce_ctrl_dec = CePsram0; psram_dec = 1'b1; quad_dec = Psram0Quad; end // PSRAM0  8 MB
      2'b11:   begin ce_ctrl_dec = CePsram1; psram_dec = 1'b1; quad_dec = Psram1Quad; end // PSRAM1  8 MB
      default: begin bad_dec = 1'b1;                                                  end // unreachable w/ 32 MB map
    endcase
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // Bridge FSM: OBI two-phase  <->  qqspi hold-until-ready                                        //
  ////////////////////////////////////////////////////////////////////////////////////////////////

  typedef enum logic [1:0] {
    IDLE, // wait for and grant an OBI A-phase request
    BUSY, // drive qqspi.valid, hold latched request until qqspi.ready
    RESP  // present the OBI R-phase response until rready
  } state_e;

  state_e state_q, state_d;

  // Latched request fields (loaded on grant, held stable across the whole access).
  logic [22:0]                 addr_q;    // word address = dec_addr[24:2]
  logic [ObiCfg.DataWidth-1:0] wdata_q;
  logic [3:0]                  wstrb_q;
  logic [ObiCfg.IdWidth-1:0]   aid_q;
  logic [NumCs-1:0]            ce_ctrl_q;
  logic                        psram_q;
  logic                        quad_q;
  logic                        err_q;

  // Captured read data.
  logic [ObiCfg.DataWidth-1:0] rdata_q;

  // qqspi handshake signals.
  logic                        q_valid;
  logic                        q_ready;
  logic [31:0]                 q_rdata;

  // A granted A-phase happens when we are idle and a request is present.
  // `accept` is INTERNAL only (may depend on req); the gnt OUTPUT must not
  // combinationally depend on any OBI input (R-22, COMB_GNT = False), so gnt
  // is driven purely from state below. Asserting gnt before req is legal (R-3.2.1).
  logic accept;
  assign accept = obi_req_i.req & (state_q == IDLE) & ~cmd_req_i;
  // qspi_cmd gets the pins only between accesses, and then no access is accepted (cmd_req_i stays high until its
  // command ends)
  assign cmd_gnt_o = cmd_req_i & (state_q == IDLE);

  // qqspi is driven only while we are in BUSY; latched inputs are held stable there.
  assign q_valid = (state_q == BUSY);

  // Next-state logic.
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      IDLE:    if (accept)              state_d = bad_dec ? RESP : BUSY;
      BUSY:    if (q_ready)             state_d = RESP;
      RESP:                             state_d = IDLE;
      default:                          state_d = IDLE;
    endcase
  end

  `FF(state_q, state_d, IDLE, clk_i, rst_ni)

  // Latch request context on grant.
  `FFL(addr_q,    dec_addr[24:2],                             accept, '0, clk_i, rst_ni)
  `FFL(wdata_q,   obi_req_i.a.wdata,                          accept, '0, clk_i, rst_ni)
  `FFL(wstrb_q,   obi_req_i.a.we ? obi_req_i.a.be : 4'b0000,  accept, '0, clk_i, rst_ni)
  `FFL(aid_q,     obi_req_i.a.aid,                            accept, '0, clk_i, rst_ni)
  `FFL(ce_ctrl_q, ce_ctrl_dec,                                accept, '0, clk_i, rst_ni)
  `FFL(psram_q,   psram_dec,                                  accept, '0, clk_i, rst_ni)
  `FFL(quad_q,    quad_dec,                                   accept, '0, clk_i, rst_ni)
  `FFL(err_q,     bad_dec,                                    accept, '0, clk_i, rst_ni)

  // Capture read data on the cycle qqspi asserts ready.
  `FFL(rdata_q,   q_rdata, (state_q == BUSY) & q_ready, '0, clk_i, rst_ni)

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // OBI response                                                                                 //
  ////////////////////////////////////////////////////////////////////////////////////////////////

  always_comb begin
    obi_rsp_o         = '0;
    obi_rsp_o.gnt     = (state_q == IDLE) & ~cmd_req_i; // idle and no command (no OBI input dependence, R-22)
    obi_rsp_o.rvalid  = (state_q == RESP);
    obi_rsp_o.r.rid   = aid_q;
    obi_rsp_o.r.err   = err_q;
    obi_rsp_o.r.rdata = err_q ? '0 : rdata_q;         // don't leak stale data on error
  end

  ////////////////////////////////////////////////////////////////////////////////////////////////
  // qqspi core                                                                                   //
  ////////////////////////////////////////////////////////////////////////////////////////////////

  qqspi #(
    .CHIP_SELECTS (NumCs)
  ) i_qqspi (
    .addr           (addr_q),
    .rdata          (q_rdata),
    .wdata          (wdata_q),
    .wstrb          (wstrb_q),
    .ready          (q_ready),
    .valid          (q_valid),
    .clk            (clk_i),
    .resetn         (rst_ni),
    .PSRAM_SPIFLASH (psram_q),
    .QUAD_MODE      (quad_q),

    .sclk           (spi_clk_o),
    .sio0_si_mosi_i (spi_sd_i[0]),
    .sio1_so_miso_i (spi_sd_i[1]),
    .sio2_i         (spi_sd_i[2]),
    .sio3_i         (spi_sd_i[3]),
    .sio0_si_mosi_o (spi_sd_o[0]),
    .sio1_so_miso_o (spi_sd_o[1]),
    .sio2_o         (spi_sd_o[2]),
    .sio3_o         (spi_sd_o[3]),
    .sio_oe         (spi_sd_en_o),
    .ce_ctrl        (ce_ctrl_q),
    .ce             (spi_csn_o)
  );

endmodule
