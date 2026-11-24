// FPGA top level for instantiating croc_soc in the ZedBoard's Zynq-7000 PL.
//
// Wraps croc_soc (the technology-independent SoC core -- NOT croc_chip,
// whose pad ring is built from ASIC-specific IO cells and does not exist
// on Xilinx parts) with:
//   - an MMCM that derives the 20 MHz system clock croc was closed at
//     (see config/clocks.tcl, CLOCK_PERIOD = 50.0 ns) from the
//     ZedBoard's onboard 100 MHz oscillator (GCLK, pin Y9)
//   - an async-assert/sync-deassert reset synchronizer
//   - explicit IOBUF primitives on every pin that is logically bidirectional
//     on the ASIC pad ring (GPIO, QSPI data lines), driven by the *_out_en
//     signals croc_soc already exposes for exactly this purpose
//   - direct pin-for-pin connections for JTAG/UART/QSPI-control, which are
//     unidirectional at the croc_soc boundary
//
// Pin mapping (see scripts/fpga/zedboard.xdc):
//   JTAG          -> Pmod JA (tck/tms/tdi/tdo/trst_n on JA1/JA2/JA3/JA4/JA7)
//   UART          -> Pmod JB (tx on JB1, rx on JB2)
//   QSPI          -> Pmod JC (clk/csn on JC1_P/JC1_N/JC2_P/JC2_N,
//                              sd[3:0] on JC3_P/JC3_N/JC4_P/JC4_N)
//   SPI bus       -> Pmod JD (SCK, MOSI, MISO on JD1..JD3, shared by the SX1276 radio and the ADS7057 ADC as on the
//                             chip). JD4 radio NSS, JD7 radio RESET, JD8 radio DIO0, JD9 ADC CS, JD10 AFE WAKE_N
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

  // croc has one SPI master for the ADC and the radio (as on the chip). On the board they are on two Pmods: this top
  // copies SCK to both and selects MISO by the ADC chip select.
  // SX1276 radio -- Pmod JB3..JB10 (JB1/JB2 are the UART)
  output wire rf_sck_o,      // JB3: radio SCK
  output wire rf_mosi_o,     // JB4: radio MOSI
  input  wire rf_miso_i,     // JB7: radio MISO
  output wire rf_nss_o,      // JB8: radio NSS, active low
  output wire rf_rstn_o,     // JB9: radio RESET, active low
  input  wire rf_dio0_i,     // JB10: radio DIO0 (TxDone, RxDone)
  // AFE v1 board (ADS7057) -- Pmod JD, plugged in upside down: board pin n is on JD pin (n + 6) mod 12
  output wire adc_cs_o,      // JD7 (board pin 1): ADC CS, active low
  input  wire adc_sdo_i,     // JD9 (board pin 3): ADC SDO
  output wire adc_sclk_o,    // JD10 (board pin 4): ADC SCLK
  input  wire afe_wake_ni,   // JD4 (board pin 10): WAKE_N, open drain, active low
  input  wire afe_big_ni,    // JD1 (board pin 7): BIG_N, open drain, active low. Not a croc port: LED only

  // GPIO -- LEDs (croc_soc's GpioCount is 2, so only two pins available)
  inout  wire [1:0] led_io,  // LD0, LD1

  // Bonus core-alive indicator
  output wire led2_o,
  // LD3 clock locked and reset released, LD4 WAKE_N, LD5 BIG_N, LD6 radio DIO0, LD7 heartbeat
  output wire [7:3] led_o
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
  // Reference clock: about 32.768 kHz (20 MHz / 610), as the crystal of the chip's ref_clk_i pad. croc_soc samples
  // ref_clk_i with clk_i in a synchronizer (CLINT mtime). Driving it with clk_20mhz itself made the clock the data
  // of that synchronizer (a hold violation, and an unreliable mtime).
  // ---------------------------------------------------------------------
  logic [8:0] ref_cnt_q;
  logic       ref_clk_q;
  always_ff @(posedge clk_20mhz or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_cnt_q <= '0;
      ref_clk_q <= 1'b0;
    end else if (ref_cnt_q == 9'd304) begin
      ref_cnt_q <= '0;
      ref_clk_q <= ~ref_clk_q;
    end else begin
      ref_cnt_q <= ref_cnt_q + 9'd1;
    end
  end

  // ---------------------------------------------------------------------
  // Shared SPI bus split over JD (ADC) and JB (radio)
  // ---------------------------------------------------------------------
  logic spi_sck, spi_sd_out, spi_sd_in, spi_cs0, spi_cs1;
  assign adc_sclk_o = spi_sck;
  assign adc_cs_o   = spi_cs0;
  assign rf_sck_o   = spi_sck;
  assign rf_mosi_o  = spi_sd_out;
  assign rf_nss_o   = spi_cs1;
  assign spi_sd_in  = !spi_cs0 ? adc_sdo_i : rf_miso_i;

  // ---------------------------------------------------------------------
  // Board LEDs: no croc ports, for bring-up only
  // ---------------------------------------------------------------------
  logic [23:0] beat_q;
  always_ff @(posedge clk_20mhz or negedge rst_ni) begin
    if (!rst_ni) beat_q <= '0;
    else         beat_q <= beat_q + 24'd1;
  end
  assign led_o[3] = rst_ni;
  assign led_o[4] = ~afe_wake_ni;
  assign led_o[5] = ~afe_big_ni;
  assign led_o[6] = rf_dio0_i;
  assign led_o[7] = beat_q[23];   // about 0.6 s period at 20 MHz

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
    .ref_clk_i      ( ref_clk_q    ),  // about 32.768 kHz, see above
    .testmode_i     ( 1'b0         ),
    .status_o       ( status       ),

    .jtag_tck_i     ( jtag_tck_i   ),
    .jtag_tdi_i     ( jtag_tdi_i   ),
    .jtag_tdo_o     ( jtag_tdo_o   ),
    .jtag_tms_i     ( jtag_tms_i   ),
    .jtag_trst_ni   ( jtag_trst_ni ),

    .uart_rx_i      ( uart_rx_i    ),
    .uart_tx_o      ( uart_tx_o    ),

    // I2C not on the board yet (v1.1 step 7 adds the Pmod pins): idle lines
    .i2c_scl_i      ( 1'b1         ),
    .i2c_scl_oe_o   (              ),
    .i2c_sda_i      ( 1'b1         ),
    .i2c_sda_oe_o   (              ),

    .qspi_clk_o     ( qspi_clk_o   ),
    .qspi_sd_o      ( qspi_sd_o    ),
    .qspi_sd_i      ( qspi_sd_i    ),
    .qspi_sd_en_o   ( qspi_sd_en   ),
    .qspi_csn_o     ( qspi_csn_o   ),

    .spi_sck_o      ( spi_sck      ),
    .spi_sd_o       ( spi_sd_out   ),
    .spi_sd_i       ( spi_sd_in    ),
    .spi_cs0_o      ( spi_cs0      ),
    .spi_cs1_o      ( spi_cs1      ),
    .afe_irq_i      ( afe_wake_ni  ),
    .rf_dio0_i      ( rf_dio0_i    ),
    .rf_rstn_o      ( rf_rstn_o    ),

    .gpio_i         ( gpio_i       ),
    .gpio_o         ( gpio_o       ),
    .gpio_out_en_o  ( gpio_out_en  )
  );

endmodule
