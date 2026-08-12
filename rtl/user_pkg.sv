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

  /// Enum with user domain demultiplexer subordinate idxs
  typedef enum bit [4:0]  {
    UserError  = 0,
    UserDesign = 1,
    UserQSpi = 2
  } user_demux_outputs_e;

  /// Address rules given to user domain demultiplexer (see croc_pkg.sv for examples)
  // IMPORTANT: rules must NOT overlap. Previously UserDesign spanned
  // 0x2000_0000..0x3000_0000 and fully contained the QSPI window, so a QSPI access
  // could be routed to the (undriven) UserDesign subordinate and return X.
  // UserDesign now starts at the end of the QSPI window.
  localparam croc_pkg::addr_map_rule_t [1:0] UserAddrMap = '{
    '{
      idx:        UserDesign,
      start_addr: UserQSpiAddrEnd,                        // 0x2200_0000
      end_addr:   croc_pkg::UserBaseAddr + 32'h1000_0000  // 0x3000_0000
    },
    '{ idx: UserQSpi, start_addr: UserQSpiAddrBase, end_addr: UserQSpiAddrEnd }
  };
  // All addresses outside the defined address rules go to the error subordinate

  // +1 for additional OBI error
  localparam int unsigned NumDemuxSbr = $size(UserAddrMap) + 1;

endpackage