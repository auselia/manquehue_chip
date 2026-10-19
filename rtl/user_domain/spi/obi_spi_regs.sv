// Copyright 2026 Auselia.
// SPDX-License-Identifier: SHL-0.51
//
// OBI subordinate front end of the SPI block. It turns every OBI request into one register access of the
// sub-blocks and answers in the next cycle.
// - gnt follows req, so every request is accepted at once (one transaction in flight at most).
// - Byte, halfword and word accesses are all accepted. The byte enables go to the sub-blocks unchanged.
// - Read data is taken from rdata_i in the request cycle and held for the response. A sub-block that pops a
//   FIFO on read does so on rd_valid_o and returns the popped value in the same cycle.
// - An access at or above obi_spi_pkg::MapEnd gets an OBI error. Writes there change nothing.

`include "common_cells/registers.svh"

module obi_spi_regs import obi_spi_pkg::*; #(
  /// The OBI configuration connected to this peripheral (SbrObiCfg)
  parameter obi_pkg::obi_cfg_t ObiCfg = obi_pkg::ObiDefaultConfig,
  /// OBI request type
  parameter type obi_req_t = logic,
  /// OBI response type
  parameter type obi_rsp_t = logic
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  input  obi_req_t                      obi_req_i,
  output obi_rsp_t                      obi_rsp_o,

  // Register access in the request cycle, word address inside the window
  output logic [AddrBits-1:0]           addr_o,
  output logic                          wr_valid_o,
  output logic [ObiCfg.DataWidth-1:0]   wdata_o,
  output logic [ObiCfg.DataWidth/8-1:0] be_o,
  output logic                          rd_valid_o,
  input  logic [ObiCfg.DataWidth-1:0]   rdata_i
);

  logic                        mapped;
  logic                        valid_q, err_q;
  logic [ObiCfg.IdWidth-1:0]   id_q;
  logic [ObiCfg.DataWidth-1:0] rdata_q;

  assign addr_o     = obi_req_i.a.addr[2 +: AddrBits];
  assign mapped     = obi_req_i.a.addr[WindowBits-1:0] < MapEnd;
  assign wr_valid_o = obi_req_i.req &  obi_req_i.a.we & mapped;
  assign rd_valid_o = obi_req_i.req & ~obi_req_i.a.we & mapped;
  assign wdata_o    = obi_req_i.a.wdata;
  assign be_o       = obi_req_i.a.be;

  `FF(valid_q, obi_req_i.req, 1'b0, clk_i, rst_ni)
  `FFL(id_q,    obi_req_i.a.aid,                      obi_req_i.req, '0,   clk_i, rst_ni)
  `FFL(err_q,   ~mapped,                              obi_req_i.req, 1'b0, clk_i, rst_ni)
  `FFL(rdata_q, (rd_valid_o ? rdata_i : '0),          obi_req_i.req, '0,   clk_i, rst_ni)

  always_comb begin
    obi_rsp_o         = '0;
    obi_rsp_o.gnt     = obi_req_i.req;
    obi_rsp_o.rvalid  = valid_q;
    obi_rsp_o.r.rid   = id_q;
    obi_rsp_o.r.err   = err_q;
    obi_rsp_o.r.rdata = rdata_q;
  end

endmodule
