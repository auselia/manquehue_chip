// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

`include "obi/typedef.svh"

package user_pkg;

  //////////////////
  // User Manager //
  //////////////////

  // None


  ///////////////////////
  // User Subordinates //
  ///////////////////////

  // The base address of the user domain can be retrived from `croc_pkg::UserBaseAddr`
  // Recommended: place subordinates at 4KB boundaries (32'hXXXX_X000)

  // 32 MB QSPI window. Base matches the boot trampoline's jump target
  // (lui t0,0x20000 -> 0x2000_0000) and obi_qspi's 32 MB-aligned bank decode.
  // (Was 0x2100_0000, which is only 16 MB-aligned and broke the flash bank decode.)
  localparam logic [31:0] UserQSpiAddrBase = 32'h2000_0000;
  localparam logic [31:0] UserQSpiAddrEnd  = UserQSpiAddrBase + 32'h0200_0000; // +32 MB -> 0x2200_0000

  // obi_spi_host (ADC + LoRa SPI master) window, right after the QSPI window.
  // spi_host's own register file only spans 256 B (BlockAw=6), so 4 KB is
  // generous headroom at the project's own recommended alignment, not a tight fit.
  localparam logic [31:0] UserSpiHostAddrBase = UserQSpiAddrEnd;                     // 0x2200_0000
  localparam logic [31:0] UserSpiHostAddrEnd  = UserSpiHostAddrBase + 32'h0000_1000; // +4KB -> 0x2200_1000

  // Pad-sharing pinmux register (1 word). Selects, per repurposed pad, whether
  // it's driven by its stock Croc peripheral or by obi_spi_host -- see the
  // mux in croc_soc.sv. 4 KB window for the same reason as above.
  localparam logic [31:0] UserPinmuxAddrBase = UserSpiHostAddrEnd;                     // 0x2200_1000
  localparam logic [31:0] UserPinmuxAddrEnd  = UserPinmuxAddrBase + 32'h0000_1000; // +4KB -> 0x2200_2000

  /// Enum with user domain demultiplexer subordinate idxs
  typedef enum bit [4:0]  {
    UserError    = 0,
    UserDesign   = 1,
    UserQSpi     = 2,
    UserSpiHost  = 3,
    UserPinmux   = 4
  } user_demux_outputs_e;

  /// Address rules given to user domain demultiplexer (see croc_pkg.sv for examples)
  // IMPORTANT: rules must NOT overlap. Previously UserDesign spanned
  // 0x2000_0000..0x3000_0000 and fully contained the QSPI window, so a QSPI access
  // could be routed to the (undriven) UserDesign subordinate and return X.
  // UserDesign now starts at the end of the pinmux window.
  localparam croc_pkg::addr_map_rule_t [3:0] UserAddrMap = '{
    '{
      idx:        UserDesign,
      start_addr: UserPinmuxAddrEnd,                      // 0x2200_2000
      end_addr:   croc_pkg::UserBaseAddr + 32'h1000_0000  // 0x3000_0000
    },
    '{ idx: UserPinmux,  start_addr: UserPinmuxAddrBase,  end_addr: UserPinmuxAddrEnd  },
    '{ idx: UserSpiHost, start_addr: UserSpiHostAddrBase, end_addr: UserSpiHostAddrEnd },
    '{ idx: UserQSpi,    start_addr: UserQSpiAddrBase,    end_addr: UserQSpiAddrEnd    }
  };
  // All addresses outside the defined address rules go to the error subordinate

  // +1 for additional OBI error
  localparam int unsigned NumDemuxSbr = $size(UserAddrMap) + 1;

endpackage
