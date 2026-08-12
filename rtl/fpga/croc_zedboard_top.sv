// FPGA top level for instantiating croc_soc in the ZedBoard's Zynq-7000 PL.
//
// Wraps croc_soc (the technology-independent SoC core -- NOT croc_chip,
// whose pad ring is built from ASIC-specific IO cells and does not exist
// on Xilinx parts) with:
//   - an MMCM that derives the 20 MHz system clock croc was closed at
//     (see scripts/common/mode_func.tcl, CLOCK_PERIOD = 50.0 ns) from the
//     ZedBoard's onboard 100 MHz oscillator (GCLK, pin Y9)
//   - an async-assert/sync-deassert reset synchronizer
//   - explicit IOBUF primitives on every pin that is logically bidirectional
//     on the ASIC pad ring (GPIO, QSPI data lines), driven by the *_out_en
//     signals croc_soc already exposes for exactly this purpose
//   - direct pin-for-pin connections for JTAG/UART/QSPI-control, which are
//     unidirectional at the croc_soc boundary
//
// Pin mapping (see constraints/zedboard.xdc):
//   JTAG          -> Pmod JA (tck/tms/tdi/tdo/trst_n on JA1/JA2/JA3/JA4/JA7)
//   UART          -> Pmod JB (tx on JB1, rx on JB2)
//   QSPI          -> Pmod JC (clk/csn on JC1_P/JC1_N/JC2_P/JC2_N,
//                              sd[3:0] on JC3_P/JC3_N/JC4_P/JC4_N)
//   GPIO[1:0]     -> LD0/LD1 (croc_soc's GpioCount default is now 2 -- wire
//                             these as outputs in software, e.g. for blink.c)
//   status_o      -> LD2 (bonus "core busy" indicator, not requested but
//                          free -- remove if LD2 is needed for something else)

module croc_zedboard_top (
  // 100 MHz onboard oscillator (GCLK)
  input  wire clk_100mhz_i,
  // Center pushbutton, active-high, async system reset
  input  wire btnc_i,

  // JTAG -- Pmod JA
  input  wire jtag_tck_i,
  input  wire jtag_tms_i,
  input  wire jtag_tdi_i,
  output wire jtag_tdo_o,
  input  wire jtag_trst_ni,

  // UART -- Pmod JB
  output wire uart_tx_o,
  input  wire uart_rx_i,

  // QSPI -- Pmod JC
  output wire       qspi_clk_o,
  output wire [2:0] qspi_csn_o,
  inout  wire [3:0] qspi_sd_io,

  // GPIO -- LEDs (croc_soc's GpioCount is 2, so only two pins available)
  inout  wire [1:0] led_io,  // LD0, LD1

  // Bonus core-alive indicator
  output wire led2_o
);

  localparam int unsigned GpioCount = 2;

  // ---------------------------------------------------------------------
  // Clock generation: 100 MHz onboard osc -> 20 MHz croc system clock
  // ---------------------------------------------------------------------
  logic clk_20mhz, clk_fb_unbuf, clk_fb, clk_20mhz_unbuf, mmcm_locked;

  MMCME2_BASE #(
    .BANDWIDTH          ( "OPTIMIZED" ),
    .CLKFBOUT_MULT_F    ( 10.0        ),
    .CLKFBOUT_PHASE     ( 0.0         ),
    .CLKIN1_PERIOD      ( 10.0        ),  // 100 MHz
    .CLKOUT0_DIVIDE_F   ( 50.0        ),  // 1000 MHz VCO / 50 = 20 MHz
    .CLKOUT0_DUTY_CYCLE ( 0.5         ),
    .CLKOUT0_PHASE      ( 0.0         ),
    .DIVCLK_DIVIDE      ( 1           ),
    .REF_JITTER1        ( 0.010       ),
    .STARTUP_WAIT       ( "FALSE"     )
  ) i_mmcm (
    .CLKIN1     ( clk_100mhz_i    ),
    .CLKFBIN    ( clk_fb          ),
    .RST        ( 1'b0            ),
    .PWRDWN     ( 1'b0            ),
    .CLKOUT0    ( clk_20mhz_unbuf ),
    .CLKOUT0B   (                 ),
    .CLKOUT1    (                 ),
    .CLKOUT1B   (                 ),
    .CLKOUT2    (                 ),
    .CLKOUT2B   (                 ),
    .CLKOUT3    (                 ),
    .CLKOUT3B   (                 ),
    .CLKOUT4    (                 ),
    .CLKOUT5    (                 ),
    .CLKOUT6    (                 ),
    .CLKFBOUT   ( clk_fb_unbuf    ),
    .CLKFBOUTB  (                 ),
    .LOCKED     ( mmcm_locked     )
  );

  BUFG i_bufg_fb  ( .I ( clk_fb_unbuf    ), .O ( clk_fb    ) );
  BUFG i_bufg_out ( .I ( clk_20mhz_unbuf ), .O ( clk_20mhz ) );

  // ---------------------------------------------------------------------
  // Reset: async-assert (button or PLL unlocked) / sync-deassert
  // ---------------------------------------------------------------------
  wire rst_async_n = ~btnc_i & mmcm_locked;

  (* ASYNC_REG = "TRUE" *) logic [2:0] rst_sync_q;

  always_ff @(posedge clk_20mhz or negedge rst_async_n) begin
    if (!rst_async_n) rst_sync_q <= 3'b000;
    else              rst_sync_q <= {rst_sync_q[1:0], 1'b1};
  end

  wire rst_ni = rst_sync_q[2];

  // ---------------------------------------------------------------------
  // GPIO tri-state buffers
  //   bit convention (matches croc_soc gpio_out_en_o): 0 = input, 1 = output
  //   [1:0] -> LEDs LD0/LD1 (drive as outputs in software)
  // ---------------------------------------------------------------------
  logic [GpioCount-1:0] gpio_i, gpio_o, gpio_out_en;

  for (genvar i = 0; i < GpioCount; i++) begin : gen_iobuf_led
    IOBUF i_iobuf_led (
      .O  ( gpio_i[i]        ),
      .IO ( led_io[i]        ),
      .I  ( gpio_o[i]        ),
      .T  ( ~gpio_out_en[i]  )
    );
  end

  // ---------------------------------------------------------------------
  // QSPI tri-state buffers (sio[3:0])
  // ---------------------------------------------------------------------
  logic [3:0] qspi_sd_i, qspi_sd_o, qspi_sd_en;

  for (genvar i = 0; i < 4; i++) begin : gen_iobuf_qspi
    IOBUF i_iobuf_qspi (
      .O  ( qspi_sd_i[i]     ),
      .IO ( qspi_sd_io[i]    ),
      .I  ( qspi_sd_o[i]     ),
      .T  ( ~qspi_sd_en[i]   )
    );
  end

  // ---------------------------------------------------------------------
  // croc_soc
  // ---------------------------------------------------------------------
  logic status;
  assign led2_o = status;

  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
    .clk_i          ( clk_20mhz    ),
    .rst_ni         ( rst_ni       ),
    .ref_clk_i      ( clk_20mhz    ),  // not used as a clock in this netlist today
    .testmode_i     ( 1'b0         ),
    .status_o       ( status       ),

    .jtag_tck_i     ( jtag_tck_i   ),
    .jtag_tdi_i     ( jtag_tdi_i   ),
    .jtag_tdo_o     ( jtag_tdo_o   ),
    .jtag_tms_i     ( jtag_tms_i   ),
    .jtag_trst_ni   ( jtag_trst_ni ),

    .uart_rx_i      ( uart_rx_i    ),
    .uart_tx_o      ( uart_tx_o    ),

    .qspi_clk_o     ( qspi_clk_o   ),
    .qspi_sd_o      ( qspi_sd_o    ),
    .qspi_sd_i      ( qspi_sd_i    ),
    .qspi_sd_en_o   ( qspi_sd_en   ),
    .qspi_csn_o     ( qspi_csn_o   ),

    .gpio_i         ( gpio_i       ),
    .gpio_o         ( gpio_o       ),
    .gpio_out_en_o  ( gpio_out_en  )
  );

endmodule
