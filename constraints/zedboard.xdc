## -----------------------------------------------------------------------
## ZedBoard (xc7z020clg484-1) constraints for croc_zedboard_top
##
## Pin numbers taken from Digilent's official Zedboard-Master.xdc
## (github.com/Digilent/digilent-xdc). Double check against your board
## revision before bring-up.
##
## Bank IOSTANDARDs on the ZedBoard (fixed by the board's supply rails):
##   Bank 13 (Pmod JA/JB/JC, GCLK) -> LVCMOS33
##   Bank 33 (LEDs)                -> LVCMOS33
##   Bank 34 (push buttons)        -> LVCMOS18
##   Bank 35 (slide switches)      -> LVCMOS18
## -----------------------------------------------------------------------

## ------------------------------------------------------------------
## Clock (100 MHz onboard oscillator -> MMCM -> 20 MHz croc clk_i)
## ------------------------------------------------------------------
set_property PACKAGE_PIN Y9   [get_ports clk_100mhz_i]
set_property IOSTANDARD LVCMOS33 [get_ports clk_100mhz_i]
create_clock -period 10.000 -name clk_100mhz [get_ports clk_100mhz_i]

## JTAG TCK is a second, fully asynchronous clock domain (external debug
## probe). dmi_jtag/dmi_cdc handle the CDC in RTL -- these are legitimate
## exception paths, not masking a real timing bug.
create_clock -period 100.000 -name jtag_tck [get_ports jtag_tck_i]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks clk_100mhz] -group [get_clocks jtag_tck]

## jtag_tck_i lands on an ordinary Pmod pin (JA1), not a clock-capable pin
## wired to a BUFG via dedicated routing. It directly clocks the JTAG TAP's
## flip-flops, so Vivado still buffers it onto a BUFG -- but the placer then
## refuses the non-dedicated IO->BUFG route by default. At ~10 MHz this is
## fine; this is Xilinx's own documented override for exactly this case.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets jtag_tck_i_IBUF]

## ------------------------------------------------------------------
## Reset -- center pushbutton (active-high on ZedBoard)
## ------------------------------------------------------------------
set_property PACKAGE_PIN P16 [get_ports btnc_i]
set_property IOSTANDARD LVCMOS18 [get_ports btnc_i]

## ------------------------------------------------------------------
## JTAG -> Pmod JA (bank 13)
## ------------------------------------------------------------------
set_property PACKAGE_PIN Y11  [get_ports jtag_tck_i]
set_property PACKAGE_PIN AA11 [get_ports jtag_tms_i]
set_property PACKAGE_PIN Y10  [get_ports jtag_tdi_i]
set_property PACKAGE_PIN AA9  [get_ports jtag_tdo_o]
set_property PACKAGE_PIN AB11 [get_ports jtag_trst_ni]
set_property IOSTANDARD LVCMOS33 [get_ports {jtag_tck_i jtag_tms_i jtag_tdi_i jtag_tdo_o jtag_trst_ni}]

## Keep the debug module out of permanent reset / TAP out of an undefined
## state when no JTAG probe is plugged into JA.
set_property PULLUP true [get_ports jtag_trst_ni]
set_property PULLUP true [get_ports jtag_tms_i]
set_property PULLUP true [get_ports jtag_tdi_i]

## ------------------------------------------------------------------
## UART -> Pmod JB (bank 13)
## ------------------------------------------------------------------
set_property PACKAGE_PIN W12 [get_ports uart_tx_o]
set_property PACKAGE_PIN W11 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_tx_o uart_rx_i}]

## ------------------------------------------------------------------
## QSPI -> Pmod JC (bank 13)
##
## Matches the TinyTapeout/mole99 QSPI flash Pmod board's own pin order
## (CS0, SD0/MOSI, SD1/MISO, SCK, SD2, SD3, CS1, CS2 across physical pins
## 1,2,3,4,7,8,9,10 -- see github.com/mole99/qspi-pmod), which is also
## exactly what the flasher itself reported: CS=1 DI=2 DO=3 CLK=4 WP=5
## HOLD/RESET=6. Physical pin -> JCn_P/N follows Digilent's standard
## sequential convention: pin1=JC1_P, pin2=JC1_N, pin3=JC2_P, pin4=JC2_N,
## pin7=JC3_P, pin8=JC3_N, pin9=JC4_P, pin10=JC4_N.
## qspi_csn_o[1]/[2] (RAM A/B chip selects) land on pins 9/10 -- unused,
## no PSRAM chip populated on this Pmod.
## ------------------------------------------------------------------
set_property PACKAGE_PIN AB7 [get_ports {qspi_csn_o[0]}]  ; # pin1 JC1_P: CS0 (flash)
set_property PACKAGE_PIN AB6 [get_ports {qspi_sd_io[0]}]  ; # pin2 JC1_N: SD0 / MOSI / DI
set_property PACKAGE_PIN Y4  [get_ports {qspi_sd_io[1]}]  ; # pin3 JC2_P: SD1 / MISO / DO
set_property PACKAGE_PIN AA4 [get_ports qspi_clk_o]       ; # pin4 JC2_N: SCK / CLK
set_property PACKAGE_PIN R6  [get_ports {qspi_sd_io[2]}]  ; # pin7 JC3_P: SD2 / WP
set_property PACKAGE_PIN T6  [get_ports {qspi_sd_io[3]}]  ; # pin8 JC3_N: SD3 / HOLD or RESET
set_property PACKAGE_PIN T4  [get_ports {qspi_csn_o[1]}]  ; # pin9 JC4_P: CS1 (RAM A, unused)
set_property PACKAGE_PIN U4  [get_ports {qspi_csn_o[2]}]  ; # pin10 JC4_N: CS2 (RAM B, unused)
set_property IOSTANDARD LVCMOS33 [get_ports {qspi_clk_o qspi_csn_o[*] qspi_sd_io[*]}]

## ------------------------------------------------------------------
## GPIO -> LEDs (bank 33). croc_soc's GpioCount is now 2, so only LD0/LD1
## are wired to the GPIO peripheral (e.g. for blink.c).
## ------------------------------------------------------------------
set_property PACKAGE_PIN T22 [get_ports {led_io[0]}]
set_property PACKAGE_PIN T21 [get_ports {led_io[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_io[*]}]

set_property PACKAGE_PIN U22 [get_ports led2_o]
set_property IOSTANDARD LVCMOS33 [get_ports led2_o]

## ------------------------------------------------------------------
## Config options
## (No BITSTREAM.CONFIG.SPI_BUSWIDTH here: that property only applies to
##  standalone 7-series parts booting from external SPI flash. This is a
##  Zynq PL bitstream, loaded by the PS over PCAP, not a config source.)
## ------------------------------------------------------------------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
