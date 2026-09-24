// Copyright and related rights waived via CC0.
//
// obi_spi_host
// -------------
// Croc-facing wrapper around OpenTitan's spi_host IP (vendored at
// earlgrey_silver_release_v3 -- see README.md in this directory for why that
// tag). Presents a plain OBI subordinate port on one side (matching every
// other Croc peripheral, e.g. obi_qspi/gpio) and the SPI pad-side signals on
// the other; the OBI<->TL-UL translation in between is entirely contained in
// obi_tlul_bridge.
//
// clk_core_i/rst_core_ni: spi_host supports running its SPI shift-register
// core on a separate (typically faster/async) clock from its TL-UL register
// port. We don't need that here -- one clock domain is simpler and Croc's
// clk_i already needs to be fast enough for the ADC's SCK -- so both are
// tied to the same clk_i/rst_ni.
//
// scanmode_i: tied to lc_ctrl_pkg::Off; see lc_ctrl_pkg.sv for why that's a
// safe permanent tie-off rather than a real life-cycle signal here.
//
// NumCS: at this vendored tag, spi_host.sv takes NumCS from
// spi_host_reg_pkg::NumCS -- a localparam baked in when spi_host_reg_pkg.sv/
// spi_host_reg_top.sv were generated from spi_host.hjson (NumCS shapes the
// CONFIGOPTS multireg array and the CSID field width, not just a port
// width), not a normal module #() parameter you can override at the
// instantiation site. The vendored copy here was generated for the hjson
// default, NumCS=1 -- one chip select. Getting the ADC+LoRa two-chip-select
// design actually needs NumCS=2, which means regenerating
// spi_host_reg_pkg.sv/spi_host_reg_top.sv (reggen against spi_host.hjson
// with NumCS's default overridden to "2"), not editing this wrapper. Until
// that's done, spi_csb_o below is deliberately sized from the real generated
// constant, not a free parameter, so this can't silently drift out of sync
// with what's actually generated.

module obi_spi_host import spi_host_reg_pkg::*; #(
  parameter obi_pkg::obi_cfg_t ObiCfg    = obi_pkg::ObiDefaultConfig,
  parameter type               obi_req_t = logic,
  parameter type               obi_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  // OBI subordinate port
  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o,

  // SPI pad-side signals
  output logic              spi_sck_o,
  output logic [NumCS-1:0]  spi_csb_o,
  output logic [3:0]        spi_sd_o,
  output logic [3:0]        spi_sd_en_o,
  input  logic [3:0]        spi_sd_i,

  // Interrupts -- wire into Croc's/user_domain's interrupt fan-in as needed
  output logic intr_error_o,
  output logic intr_spi_event_o
);

  tlul_pkg::tl_h2d_t tl_h2d;
  tlul_pkg::tl_d2h_t tl_d2h;

  obi_tlul_bridge #(
    .ObiCfg    ( ObiCfg    ),
    .obi_req_t ( obi_req_t ),
    .obi_rsp_t ( obi_rsp_t )
  ) i_bridge (
    .clk_i,
    .rst_ni,
    .obi_req_i,
    .obi_rsp_o,
    .tl_h2d_o ( tl_h2d ),
    .tl_d2h_i ( tl_d2h )
  );

  // cio_sck_en_o/cio_csb_en_o: at this spi_host version these are tied
  // '1 internally (always-driven pads, no tristate case to handle) -- left
  // unconnected here since our pinmux (in user_domain.sv) owns pad
  // direction/enable on the Croc side, not spi_host's own idea of it.
  spi_host i_spi_host (
    .clk_i,
    .rst_ni,
    .clk_core_i  ( clk_i  ),
    .rst_core_ni ( rst_ni ),
    .scanmode_i  ( lc_ctrl_pkg::Off ),

    .tl_i ( tl_h2d ),
    .tl_o ( tl_d2h ),

    .cio_sck_o    ( spi_sck_o   ),
    .cio_sck_en_o (             ),
    .cio_csb_o    ( spi_csb_o   ),
    .cio_csb_en_o (             ),
    .cio_sd_o     ( spi_sd_o    ),
    .cio_sd_en_o  ( spi_sd_en_o ),
    .cio_sd_i     ( spi_sd_i    ),

    .intr_error_o,
    .intr_spi_event_o
  );

endmodule
