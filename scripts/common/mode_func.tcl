###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Functional-mode constraints for croc_soc
###############################################################################

current_mode func

# Main system clock.
if { ![info exists CLOCK_PORT_NAME] } { set CLOCK_PORT_NAME "clk_i" }
if { ![info exists CLOCK_PERIOD]    } { set CLOCK_PERIOD    50.0    }

# JTAG test clock, driven off-chip by the debug probe
set JTAG_TCK_PORT   "jtag_tck_i"
set JTAG_TCK_PERIOD 100.0; # 10 MHz

# Margins
set SETUP_UNCERT 2.75; # Based on v0.1 clock QOR report
set HOLD_UNCERT      0.25; # Based on v0.1 clock QOR report +0.23 ns slack.
set CLOCK_IDEAL_TRAN 0.4; # TODO: Educated guess.

# Off-chip environment
set IO_DELAY_FRAC    0.20   ;# fraction of period for delay outside the macro: pad (3 ns in / 7-12 ns out, gf180mcu_fd_io) + board
set EXT_INPUT_TRAN   0.3    ;# ns, input-pad Y slew into the macro (TODO: read from IO liberty)
set EXT_LOAD         0.2    ;# pF, pad A-pin cap + macro-to-pad wire (TODO: read from IO liberty)

# Design rule constraints.
set MAX_TRAN_DATA    1.5
set MAX_TRAN_CLK     0.5
set MAX_CAP          0.3
set MAX_FANOUT       20


################################################################################
# 1. Clocks
################################################################################

create_clock -name clock \
             -period $CLOCK_PERIOD \
             [get_ports $CLOCK_PORT_NAME]

# Without it the TAP and DMI CDC flops (283 in i_dmi_jtag) have no clock: no timing and no CTS.
create_clock -name jtag_tck \
             -period $JTAG_TCK_PERIOD \
             [get_ports $JTAG_TCK_PORT]

# SCLK of the ADS7057: the system clock through a clock gate and an inverter (adc_rdr, spec section 6) leaves
# through adc_sclk_o. It idles high and falls at the rising edge of clk_i. The flow experiment
# sim/experiments/fwd_clock showed that CTS handles a clock that ends at a port without special settings.
create_generated_clock -name adc_sclk -source [get_ports $CLOCK_PORT_NAME] -divide_by 1 -invert \
             [get_ports adc_sclk_o]

################################################################################
# 2. Clock properties
################################################################################

set_clock_uncertainty -mode func -setup $SETUP_UNCERT [get_clocks clock]
set_clock_uncertainty -mode func -hold  $HOLD_UNCERT  [get_clocks clock]
set_clock_uncertainty -mode func -setup $SETUP_UNCERT [get_clocks adc_sclk]
set_clock_uncertainty -mode func -hold  $HOLD_UNCERT  [get_clocks adc_sclk]

# TCK is slow and off-chip: fixed margins.
set_clock_uncertainty -mode func -setup 2.0 [get_clocks jtag_tck]
set_clock_uncertainty -mode func -hold  0.5 [get_clocks jtag_tck]

set_clock_transition $CLOCK_IDEAL_TRAN [get_clocks *]



################################################################################
# 3. Clock groups
#
# clk_i and jtag_tck_i have no phase relation. The RTL crosses safely (cdc_2phase and the reset controller in
# i_dmi_jtag, i_dmi_cdc), so the crossing is not timed.
################################################################################

# adc_sclk is derived from clk_i, so it is synchronous to it and in the same group.
set GRP_SYS [get_clocks {clock adc_sclk}]

  set_clock_groups -asynchronous -name async_domains \
    -group $GRP_SYS \
    -group [get_clocks jtag_tck]



################################################################################
# 4. Case analysis, functional mode
#
# testmode_i is 0 in operation. It drives i_rstgen.test_mode_i, the SRAM test bypass and the ICG test-enable
# pins, so those paths are not timed and need no false path.
################################################################################

set_case_analysis 0 [get_ports testmode_i]

# scan_se_i is 0: the scan muxes and the reset and set gating are timed in their functional position.
set_case_analysis 0 [get_ports scan_se_i]


################################################################################
# 5. Port classification
#
# Ports of croc_soc.sv:
#   in : clk_i rst_ni ref_clk_i testmode_i fetch_en_i
#        jtag_tck_i jtag_tdi_i jtag_tms_i jtag_trst_ni
#        uart_rx_i qspi_sd_i[3:0] gpio_i[15:0]
#        adc_sdo_i adc_wake_n_i adc_big_n_i rf_miso_i rf_dio0_i
#   out: status_o jtag_tdo_o uart_tx_o
#        qspi_clk_o qspi_sd_o[3:0] qspi_sd_en_o[3:0] qspi_csn_o[2:0]
#        gpio_o[15:0] gpio_out_en_o[15:0]
#        adc_sclk_o adc_csn_o adc_wake_clr_o adc_cap_en_o
#        rf_sclk_o rf_mosi_o rf_csn_o rf_rstn_o
################################################################################

set CLK_PORTS [get_ports [list $CLOCK_PORT_NAME $JTAG_TCK_PORT]]

# Asynchronous or static, no clock launches them:
#   rst_ni        async reset of i_rstgen
#   jtag_trst_ni  async reset of the TAP
#   fetch_en_i    static strap into a 2-FF synchronizer (i_ext_intr_sync)
#   testmode_i    case analysis above
set ASYNC_PORTS [get_ports {rst_ni jtag_trst_ni fetch_en_i testmode_i scan_se_i}]

# JTAG data pins are in the tck domain.
set JTAG_IN  [get_ports {jtag_tdi_i jtag_tms_i}]
set JTAG_OUT [get_ports {jtag_tdo_o}]

# All other I/O is in the clk_i domain:
#   ref_clk_i, uart_rx_i, gpio_i  asynchronous, but each goes into a 2-FF synchronizer. Timing them costs nothing.
#   qspi_sd_i                     captured by a clk_i flop
#   rf_* (rf_spi)                 SCLK, MOSI, CS and RSTN from clk_i flops, MISO captured by clk_i flops, DIO0 into
#                                 a 2-FF synchronizer. MISO is sampled one clk_i period or more after the SCLK edge
#                                 that launched it (CLKDIV 0, SCLK = clk/2), so the clk_i budget is the worst case.
# The ADS7057 interface is timed against adc_sclk (section 9).
set ADC_IN  [get_ports {adc_sdo_i adc_wake_n_i adc_big_n_i}]
set ADC_OUT [get_ports {adc_sclk_o adc_csn_o}]

set FUNC_IN  [all_inputs]
foreach coll [list $CLK_PORTS $ASYNC_PORTS $JTAG_IN $ADC_IN] {
  if { [sizeof_collection $coll] > 0 } {
    set FUNC_IN [remove_from_collection $FUNC_IN $coll]
  }
}

set FUNC_OUT [all_outputs]
foreach coll [list $JTAG_OUT $ADC_OUT] {
  if { [sizeof_collection $coll] > 0 } {
    set FUNC_OUT [remove_from_collection $FUNC_OUT $coll]
  }
}


################################################################################
# 6. Asynchronous and static inputs: false paths
################################################################################

set_false_path -from [get_ports rst_ni]
set_false_path -from [get_ports jtag_trst_ni]
set_false_path -from [get_ports fetch_en_i]

# WAKE_N and BIG_N of the AFE board land in 2-FF synchronizers (adc_rdr).
set_false_path -from [get_ports {adc_wake_n_i adc_big_n_i}]

# This cuts only the path from the port to the first flop. Recovery and removal from the i_rstgen synchronizer to
# the reset pins of the flops stay timed against `clock`.


################################################################################
# 7. Functional I/O, clk_i domain
################################################################################

set IO_DELAY [expr {$IO_DELAY_FRAC * $CLOCK_PERIOD}]

set_input_delay  -mode func -clock clock $IO_DELAY $FUNC_IN
set_output_delay -mode func -clock clock $IO_DELAY $FUNC_OUT

################################################################################
# 8. JTAG I/O, against tck
################################################################################

set JTAG_IO_DELAY [expr {$IO_DELAY_FRAC * $JTAG_TCK_PERIOD}]

# The TAP samples TDI and TMS on the rising edge of TCK.
set_input_delay -mode func -clock jtag_tck $JTAG_IO_DELAY $JTAG_IN

# The TAP launches TDO on the falling edge of TCK (IEEE 1149.1).
set_output_delay -mode func -clock jtag_tck -clock_fall $JTAG_IO_DELAY $JTAG_OUT

################################################################################
# 9. ADS7057 interface, against adc_sclk
#
# Datasheet SBAS821 tables 6.5 to 6.7 and the off-chip budget of the flow
# experiment (sim/experiments/fwd_clock/constraints.sdc): pad out 7 to 12 ns on
# every output, so 5 ns of spread between the CS pad and the SCLK pad, pad in
# 3 ns, level translator 5 ns, trace 1 ns.
################################################################################

set ADC_PAD_SPREAD 5.0
# CS low at least 7 ns before the first SCLK falling edge (tsu_CSCK) and high at least 8 ns after the last
# SCLK rising edge (tht_CKCS).
set_output_delay -mode func -clock adc_sclk -clock_fall -max [expr {7.0 + $ADC_PAD_SPREAD}] [get_ports adc_csn_o]
set_output_delay -mode func -clock adc_sclk             -min -8.0 -add_delay           [get_ports adc_csn_o]
# SDO is launched by the SCLK rising edge: valid 10 ns max after it, held 2.5 ns min, plus pad, translator and
# trace. It is captured by clk_i half a clock later (or a full clock later with SDO_NEG, which is not timed
# here: the default capture is the critical one).
set_input_delay  -mode func -clock adc_sclk -max [expr {10.0 + 3.0 + 5.0 + 1.0}]     [get_ports adc_sdo_i]
set_input_delay  -mode func -clock adc_sclk -min [expr {2.5 + 1.0 + 3.0}] -add_delay [get_ports adc_sdo_i]


################################################################################
# 10. Drive and load
#
# Without them the tool assumes an ideal driver and no load.
################################################################################

# set_load applies to the current corner and set_input_transition to the current scenario, so set them in every
# scenario (else only fast, the current one, gets them).
set previous_scenario [current_scenario]
foreach_in_collection scenario [all_scenarios] {
  current_scenario $scenario
  set_input_transition $EXT_INPUT_TRAN [all_inputs]
  set_load             $EXT_LOAD       [all_outputs]
}
current_scenario $previous_scenario


################################################################################
# 11. Design rule constraints
################################################################################

set_max_transition  $MAX_TRAN_DATA [current_design]
set_max_transition  $MAX_TRAN_CLK  [get_clocks *] -clock_path
set_max_capacitance $MAX_CAP       [current_design]
set_max_fanout      $MAX_FANOUT    [current_design]


# report_constraint -all_violators
