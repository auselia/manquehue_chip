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

  // Two managers share the user manager port through an obi_mux: the ADC reader of the SPI block and the
  // AE-FFT accelerator.
  typedef enum int unsigned {
    UserMgrSpi = 0,
    UserMgrFft = 1
  } user_mgr_ports_e;
  localparam int unsigned NumUserMgr = 2;


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

  // SPI block (radio master and ADS7057 reader), docs/spi_adc_spec.md section 3
  localparam logic [31:0] UserSpiAddrBase  = 32'h2200_0000;
  localparam logic [31:0] UserSpiAddrEnd   = UserSpiAddrBase + 32'h0000_1000; // 4 KB
  // AE-FFT accelerator (fft_hwpe), rtl/user_domain/fft
  localparam logic [31:0] UserFftAddrBase  = 32'h2200_1000;
  localparam logic [31:0] UserFftAddrEnd   = UserFftAddrBase + 32'h0000_1000; // 4 KB
  localparam logic [31:0] UserDesignAddrBase = 32'h2200_2000;

  /// Enum with user domain demultiplexer subordinate idxs
  typedef enum bit [4:0]  {
    UserError  = 0,
    UserDesign = 1,
    UserQSpi   = 2,
    UserSpi    = 3,
    UserFft    = 4
  } user_demux_outputs_e;

  /// Address rules given to user domain demultiplexer (see croc_pkg.sv for examples)
  // IMPORTANT: rules must NOT overlap. Previously UserDesign spanned
  // 0x2000_0000..0x3000_0000 and fully contained the QSPI window, so a QSPI access
  // could be routed to the (undriven) UserDesign subordinate and return X.
  // UserDesign starts after the SPI and FFT windows.
  localparam croc_pkg::addr_map_rule_t [3:0] UserAddrMap = '{
    '{
      idx:        UserDesign,
      start_addr: UserDesignAddrBase,                     // 0x2200_2000
      end_addr:   croc_pkg::UserBaseAddr + 32'h1000_0000  // 0x3000_0000
    },
    '{ idx: UserFft,  start_addr: UserFftAddrBase,  end_addr: UserFftAddrEnd  },
    '{ idx: UserSpi,  start_addr: UserSpiAddrBase,  end_addr: UserSpiAddrEnd  },
    '{ idx: UserQSpi, start_addr: UserQSpiAddrBase, end_addr: UserQSpiAddrEnd }
  };
  // All addresses outside the defined address rules go to the error subordinate

  // +1 for additional OBI error
  localparam int unsigned NumDemuxSbr = $size(UserAddrMap) + 1;

endpackage