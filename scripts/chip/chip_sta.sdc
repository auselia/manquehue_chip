###############################################################################
# Croc SoC Chip
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Sign-off constraints of chip_top for PrimeTime (make chip-sta)
###############################################################################

# The constraints of mode_func.tcl, moved from the croc ports to the chip pads. At chip level the pad cells are in
# the timed paths, so the external delays hold only the board part of the budget:
#   macro: IO_DELAY_FRAC 0.20 of the period for pad + board
#   chip:  BOARD_DELAY_FRAC 0.10 of the period for the board, the pads are timed from the IO liberty
# The ADS7057 numbers keep the datasheet, level translator and trace, without the pad values of the macro SDC.
# The QSPI flash is timed against its SCK at the qspi_clk_o pad (qspi_sck), as the ADC against its SCLK.
# The radio SPI (SCLK from a clk_i flop, 10 MHz at most) stays in the clk_i budget: its margins are large.
# The DC-DC, analog and unused pads have no digital path and get no constraint.

# PrimeTime signs off at 55 ns. Fusion Compiler reads this file too (mode_func_chip.tcl) and implements at
# CHIP_SDC_PERIOD (CLOCK_PERIOD, 50 ns), the same margin as the macro flow.
set SPEC_PERIOD      [expr {[info exists CHIP_SDC_PERIOD] ? $CHIP_SDC_PERIOD : 55.0}]
set JTAG_PERIOD      100.0
# Design rules, loads and input slews belong to a scenario in Fusion Compiler: set them in every one. PrimeTime has
# no scenarios and runs the body once.
proc chip_every_scenario {body} {
  if {[info commands all_scenarios] eq ""} {
    uplevel 1 $body
  } else {
    set prev [current_scenario]
    foreach_in_collection s [all_scenarios] { current_scenario $s; uplevel 1 $body }
    current_scenario $prev
  }
}
set BOARD_DELAY_FRAC 0.10
set BOARD_LOAD       5.0    ;# pF on each output pad: board trace, connector and receiver (assumption)
set BOARD_TRAN       1.0    ;# ns, slew of the board signal at each input pad (the max_transition of the PAD pin)

# 1. Clocks, on the pads. The clock tree after the pad is propagated from the SPEF.
create_clock -name clock    -period $SPEC_PERIOD [get_ports clk_i]
create_clock -name jtag_tck -period $JTAG_PERIOD [get_ports jtag_tck_i]
# SCLK of the ADS7057 leaves through the spi_sck_o pad, so the pad delay is in the clock path.
create_generated_clock -name adc_sclk -source [get_ports clk_i] -divide_by 1 -invert [get_ports spi_sck_o]
# QSPI SCK is a flop of the clk_i domain (qqspi.v, sclk), toggled every clk_i cycle during a transfer: half the
# clk_i frequency at most. The flash timing is relative to the SCK edges at the qspi_clk_o pad, after the clock
# tree, the flop and the pad. The flash drives its data on the falling edge, the next clk_i edge samples it (the
# edge that raises SCK). Our data changes at the falling edge, the flash samples it at the next rising edge.
create_generated_clock -name qspi_sck -source [get_ports clk_i] -divide_by 2 [get_ports qspi_clk_o]
# Sign-off times the real clock tree. Fusion Compiler keeps ideal clocks until CTS, with the transition of the macro
# flow (mode_func.tcl), and propagates them itself in clock_opt.
if {[info commands all_scenarios] eq ""} {
  set_propagated_clock [all_clocks]
  set_clock_transition 2.0 [get_clocks {clock jtag_tck}]
} else {
  set_clock_transition 0.4 [get_clocks *]
}

set_clock_uncertainty -setup 2.75 [get_clocks {clock adc_sclk qspi_sck}]
set_clock_uncertainty -hold  0.25 [get_clocks {clock adc_sclk qspi_sck}]
set_clock_uncertainty -setup 2.0  [get_clocks jtag_tck]
set_clock_uncertainty -hold  0.5  [get_clocks jtag_tck]
set_clock_groups -asynchronous -name async_domains -group [get_clocks {clock adc_sclk qspi_sck}] -group [get_clocks jtag_tck]

# The ADC SCLK mux (adc_rdr.sv, i_sclk_mux) selects the gated clock or SCLK_HALF with fhalf_q. fhalf_q changes only at
# the start of a frame, while gate_en_q is 0 and the gated clock is still, so the switch cannot glitch. The clock
# gating check that PrimeTime puts on the gates of that mux assumes a running clock: it is not a real check.
source [file dirname [info script]]/../common/sclk_gating.tcl

# 2. Functional mode: testmode_i is 0.
set_case_analysis 0 [get_ports testmode_i]

# 3. Asynchronous inputs (each into a synchronizer or a reset controller).
set_false_path -from [get_ports {rst_ni jtag_trst_ni afe_irq_i}]
# GPIO, UART RX, the radio DIO0 and ref_clk_i have no phase relation to clk_i on the board. Each goes into a 2-FF
# synchronizer, so the hold check of that first flop is not a real check. Setup stays timed, it costs nothing.
set_false_path -hold -from [get_ports {ref_clk_i uart_rx_i rf_dio0_i gpio0_io gpio1_io}]

# 4. Port groups
set JTAG_IN  [get_ports {jtag_tdi_i jtag_tms_i}]
set JTAG_OUT [get_ports {jtag_tdo_o}]
set FUNC_IN  [get_ports {ref_clk_i uart_rx_i rf_dio0_i gpio0_io gpio1_io}]
# The QSPI chip selects change only while SCK is idle (high), cycles away from any SCK edge: they are clk_i outputs.
set FUNC_OUT [get_ports {status_o uart_tx_o rf_rstn_o spi_sd_o spi_cs1_o gpio0_io gpio1_io qspi_cs0_o qspi_cs1_o qspi_cs2_o}]
set QSPI_IN  [get_ports {qspi_sd0_io qspi_sd1_io qspi_sd2_io qspi_sd3_io}]
set QSPI_OUT [get_ports {qspi_sd0_io qspi_sd1_io qspi_sd2_io qspi_sd3_io}]

# 5. clk_i domain. -max is the board budget, -min 0 is the earliest the board can be (the worst case for hold).
set BOARD_DELAY [expr {$BOARD_DELAY_FRAC * $SPEC_PERIOD}]
set_input_delay  -clock clock -max $BOARD_DELAY $FUNC_IN
set_input_delay  -clock clock -min 0.0 -add_delay $FUNC_IN
set_output_delay -clock clock -max $BOARD_DELAY $FUNC_OUT
set_output_delay -clock clock -min 0.0 -add_delay $FUNC_OUT

# 6. JTAG (IEEE 1149.1): the probe changes TDI and TMS on the falling edge of TCK, the TAP samples them on the rising
# edge. TDO is launched on the falling edge and the probe samples it on the rising edge.
set JTAG_DELAY [expr {$BOARD_DELAY_FRAC * $JTAG_PERIOD}]
set_input_delay  -clock jtag_tck -clock_fall -max $JTAG_DELAY $JTAG_IN
set_input_delay  -clock jtag_tck -clock_fall -min 0.0 -add_delay $JTAG_IN
set_output_delay -clock jtag_tck -clock_fall -max $JTAG_DELAY $JTAG_OUT
set_output_delay -clock jtag_tck -clock_fall -min 0.0 -add_delay $JTAG_OUT

# 6b. QSPI flash (W25Q128JW class): output valid 7 ns max and held 1.5 ns min after the SCK falling edge, data
# setup 2 ns and hold 3 ns at the rising edge, trace 1 ns. These are typical flash numbers: check them against the
# flash on the board.
# Our data and output enables change only at the clk_i edges where SCK falls, never where it rises. The hold check
# against the SCK rising edge at the same clk_i edge is not a real one: it moves to the rising edge before.
set_multicycle_path -hold 1 -from [get_clocks clock] -to [get_clocks qspi_sck]
set_input_delay  -clock qspi_sck -clock_fall -max [expr {7.0 + 1.0}] $QSPI_IN
set_input_delay  -clock qspi_sck -clock_fall -min 1.5 -add_delay $QSPI_IN
set_output_delay -clock qspi_sck -max [expr {2.0 + 1.0}] [get_ports {qspi_sd0_io qspi_sd1_io qspi_sd2_io qspi_sd3_io}]
set_output_delay -clock qspi_sck -min -3.0 -add_delay [get_ports {qspi_sd0_io qspi_sd1_io qspi_sd2_io qspi_sd3_io}]

# 7. ADS7057 (SBAS821 tables 6.5 to 6.7): level translator 5 ns, trace 1 ns.
# CS low at least 7 ns before the first SCLK falling edge, high at least 8 ns after the last SCLK rising edge.
set_output_delay -clock adc_sclk -clock_fall -max 7.0  [get_ports spi_cs0_o]
set_output_delay -clock adc_sclk -min -8.0 -add_delay [get_ports spi_cs0_o]
# SDO valid 10 ns max after the SCLK rising edge, held 2.5 ns min.
set_input_delay -clock adc_sclk -max [expr {10.0 + 5.0 + 1.0}] [get_ports spi_sd_i]
set_input_delay -clock adc_sclk -min [expr {2.5 + 1.0}] -add_delay [get_ports spi_sd_i]
# The firmware sets SDO_NEG (ADC CTRL bit 12): SDO goes into a falling-edge flop of clk_i (sdo_neg_cap_q), half a
# clock later than the default capture. The round trip through the SCLK and SDO pads does not fit in the default
# half period at the slow corner (-1.76 ns at chip level). The default path, straight into the shift register, is
# not used: no path to it from the SDO pad. The path into sdo_neg_cap_q stays timed.
set ADC_SH_FLOPS [get_cells -quiet -hierarchical -filter "is_sequential == true && full_name =~ *adc_rdr*sh_q*"]
if {[sizeof_collection $ADC_SH_FLOPS] > 0} {
  set_false_path -from [get_clocks adc_sclk] -through [get_ports spi_sd_i] -to $ADC_SH_FLOPS
}
# spi_sd_i is a shared MISO: the ADS7057 SDO and the radio MISO. The radio samples it only while it owns the bus, with its
# own SCLK (a clk_i flop, 10 MHz at most), never with the ADC SCLK. So the ADC timing does not apply to the radio
# receive flops: no path from adc_sclk to them. The radio MISO is a clk_i input with the board budget.
set RF_SPI_FLOPS [get_cells -quiet -hierarchical -filter "is_sequential == true && full_name =~ *rf_spi*"]
if {[sizeof_collection $RF_SPI_FLOPS] > 0} {
  set_false_path -from [get_clocks adc_sclk] -to $RF_SPI_FLOPS
}
set_input_delay -clock clock -max $BOARD_DELAY -add_delay [get_ports spi_sd_i]
set_input_delay -clock clock -min 0.0 -add_delay [get_ports spi_sd_i]
# the radio MISO changes only at the SCLK edges where rf_spi does not sample (as QSPI): its hold check is not real
if {[sizeof_collection $RF_SPI_FLOPS] > 0} {
  set_false_path -hold -from [get_ports spi_sd_i] -to $RF_SPI_FLOPS
}
# and the ADC flops (adc_rdr) take spi_sd_i only against adc_sclk: no clk_i-relative path to them
set ADC_RDR_FLOPS [get_cells -quiet -hierarchical -filter "is_sequential == true && full_name =~ *adc_rdr*"]
if {[sizeof_collection $ADC_RDR_FLOPS] > 0} {
  set_false_path -from [get_clocks clock] -through [get_ports spi_sd_i] -to $ADC_RDR_FLOPS
}

# 8. Board drive and load on the digital pads
set DIG_IN  [get_ports {clk_i jtag_tck_i rst_ni jtag_trst_ni testmode_i afe_irq_i spi_sd_i}]
set ALL_IN  [add_to_collection [add_to_collection [add_to_collection $FUNC_IN $JTAG_IN] $DIG_IN] $QSPI_IN]
set ALL_OUT [add_to_collection [add_to_collection [add_to_collection $FUNC_OUT $JTAG_OUT] $QSPI_OUT] \
    [get_ports {spi_sck_o spi_cs0_o qspi_clk_o}]]
chip_every_scenario {
  set_input_transition $BOARD_TRAN $ALL_IN
  set_load $BOARD_LOAD $ALL_OUT
}
# design rules for implementation only (common/design_rules.tcl): sign-off checks the library limits
if {[info commands all_scenarios] ne ""} {
  source [file dirname [info script]]/../common/design_rules.tcl
  design_rules
}
