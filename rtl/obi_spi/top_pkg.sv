// Copyright and related rights waived via CC0.
//
// Minimal, project-local stand-in for OpenTitan's chip-generated top_pkg.
//
// Real OpenTitan tops (Earlgrey, ...) generate this package via `topgen` for
// the whole chip's TL-UL fabric, sized for however many hosts/devices and
// however wide an address space that specific chip has. We only need it to
// size tlul_pkg's tl_h2d_t/tl_d2h_t structs for a single point-to-point link
// (obi_tlul_bridge <-> spi_host), so it's hand-written here instead of
// pulling in OpenTitan's topgen tooling for one package.
package top_pkg;
  parameter int unsigned TL_AW  = 32;        // address width -- matches Croc's OBI AddrWidth
  parameter int unsigned TL_DW  = 32;        // data width    -- matches Croc's OBI DataWidth
  parameter int unsigned TL_DBW = TL_DW / 8; // byte-mask width
  parameter int unsigned TL_SZW = 2;         // size field width (0..2 => 1/2/4 bytes; we only use 4)
  // Source-ID width: generous fixed width, wider than Croc's actual OBI IdWidth
  // (which depends on NumXbarManagers and so isn't a fixed constant). The
  // bridge zero-extends Croc's aid into this field and truncates it back on
  // the way out, so this only needs to be >= the real IdWidth, not equal to it.
  parameter int unsigned TL_AIW = 8;
  parameter int unsigned TL_DIW = 1;         // sink-ID width -- unused, single sink
endpackage
