###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Functional-mode constraints for croc_soc
###############################################################################

current_mode func

# Main system clock.
if { ![info exists CLOCK_PORT_NAME] } { set CLOCK_PORT_NAME "clk_i" }
if { ![info exists CLOCK_PERIOD]    } { set CLOCK_PERIOD    50.0    }

# JTAG test clock. Driven off-chip by the debug probe
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

# THE fix. Without this the entire TAP + DMI CDC (283 flops in i_dmi_jtag) has
# no clock: they are dropped from timing, dropped from CTS, and left to the
# router. Every 'unclocked' endpoint in check_timing.rpt lives here.
create_clock -name jtag_tck \
             -period $JTAG_TCK_PERIOD \
             [get_ports $JTAG_TCK_PORT]

################################################################################
# 3. Clock properties
################################################################################

set_clock_uncertainty -mode func -setup $SETUP_UNCERT [get_clocks clock]
set_clock_uncertainty -mode func -hold  $HOLD_UNCERT  [get_clocks clock]

# TCK is slow and off-chip: loose, fixed margins.
set_clock_uncertainty -mode func -setup 2.0 [get_clocks jtag_tck]
set_clock_uncertainty -mode func -hold  0.5 [get_clocks jtag_tck]

set_clock_transition $CLOCK_IDEAL_TRAN [get_clocks *]

# After CTS the flow must switch to the real network. clock_opt does this, but
# if you are running stages by hand:
#     set_propagated_clock [all_clocks]


################################################################################
# 4. Clock groups
#
# clk_i and jtag_tck_i have no phase relationship whatsoever. Without this the
# tool tries to time the dmi_cdc 2-phase crossing synchronously -- meaningless
# and unfixable. The RTL already handles the crossing safely (cdc_2phase +
# reset controller in i_dmi_jtag/i_dmi_cdc).
################################################################################

set GRP_SYS [get_clocks clock]

  set_clock_groups -asynchronous -name async_domains \
    -group $GRP_SYS \
    -group [get_clocks jtag_tck]

# ADVANCED (do this only after the basic version closes): instead of fully
# cutting the CDC, keep the asynchronous crosstalk model but still bound the
# wire delay on the crossing, so the multi-bit data_src_q -> data_dst_q skew
# inside cdc_2phase stays sane:
#
#   set_clock_groups -asynchronous -allow_paths -name async_domains \
#     -group [get_clocks clock] -group [get_clocks jtag_tck]
#   set_max_delay $JTAG_TCK_PERIOD -ignore_clock_latency \
#     -from [get_clocks jtag_tck] -to [get_clocks clock]
#   set_max_delay $CLOCK_PERIOD    -ignore_clock_latency \
#     -from [get_clocks clock]     -to [get_clocks jtag_tck]


################################################################################
# 5. Case analysis -- functional mode
#
# testmode_i is 0 in functional operation. It feeds i_rstgen.test_mode_i, the
# SRAM test bypass, and the ICG test-enable pins. Pinning it removes those paths
# from timing instead of leaving the tool to optimize logic that can never
# switch. This also means testmode_i needs no false path -- case analysis
# already removes it.
################################################################################

set_case_analysis 0 [get_ports testmode_i]


################################################################################
# 6. Port classification
#
# Verified against croc_soc.sv. Full port list:
#   in : clk_i rst_ni ref_clk_i testmode_i fetch_en_i
#        jtag_tck_i jtag_tdi_i jtag_tms_i jtag_trst_ni
#        uart_rx_i qspi_sd_i[3:0] gpio_i[15:0]
#   out: status_o jtag_tdo_o uart_tx_o
#        qspi_clk_o qspi_sd_o[3:0] qspi_sd_en_o[3:0] qspi_csn_o[2:0]
#        gpio_o[15:0] gpio_out_en_o[15:0]
################################################################################

set CLK_PORTS [get_ports [list $CLOCK_PORT_NAME $JTAG_TCK_PORT]]

# Asynchronous / static. Never launched by any clock, so a setup check against
# `clock` (which is what the old all_inputs sweep produced) is meaningless.
#   rst_ni       -> i_rstgen async reset input
#   jtag_trst_ni -> TAP async reset
#   fetch_en_i   -> static strap, lands in i_ext_intr_sync (2-FF synchronizer)
#   testmode_i   -> already handled by case analysis above
set ASYNC_PORTS [get_ports {rst_ni jtag_trst_ni fetch_en_i testmode_i}]

# JTAG data pins live in the tck domain, not the clk_i domain.
set JTAG_IN  [get_ports {jtag_tdi_i jtag_tms_i}]
set JTAG_OUT [get_ports {jtag_tdo_o}]

# Everything else: functional I/O in the clk_i domain.
#   ref_clk_i, uart_rx_i, gpio_i  -> async in reality, but each lands one gate
#                                    from a 2-FF synchronizer, so constraining
#                                    them costs nothing and keeps them visible.
#   qspi_sd_i                     -> genuinely captured by a clk_i flop.
set FUNC_IN  [all_inputs]
foreach coll [list $CLK_PORTS $ASYNC_PORTS $JTAG_IN] {
  if { [sizeof_collection $coll] > 0 } {
    set FUNC_IN [remove_from_collection $FUNC_IN $coll]
  }
}

set FUNC_OUT [all_outputs]
foreach coll [list $JTAG_OUT] {
  if { [sizeof_collection $coll] > 0 } {
    set FUNC_OUT [remove_from_collection $FUNC_OUT $coll]
  }
}


################################################################################
# 7. Asynchronous / static inputs -> false paths
################################################################################

set_false_path -from [get_ports rst_ni]
set_false_path -from [get_ports jtag_trst_ni]
set_false_path -from [get_ports fetch_en_i]

# This only cuts the PORT-to-first-flop asynchronous path. The recovery/removal
# checks from i_rstgen's synchronizer output to every flop's async reset pin are
# still timed against `clock` -- correct, and what you want.


################################################################################
# 8. Functional I/O -- clk_i domain
################################################################################

set IO_DELAY [expr {$IO_DELAY_FRAC * $CLOCK_PERIOD}]

set_input_delay  -mode func -clock clock $IO_DELAY $FUNC_IN
set_output_delay -mode func -clock clock $IO_DELAY $FUNC_OUT

################################################################################
# 9. JTAG I/O -- constrained against tck, not clk
################################################################################

set JTAG_IO_DELAY [expr {$IO_DELAY_FRAC * $JTAG_TCK_PERIOD}]

# The TAP samples TDI/TMS on the RISING edge of TCK.
set_input_delay -mode func -clock jtag_tck $JTAG_IO_DELAY $JTAG_IN

# The TAP launches TDO on the FALLING edge of TCK (IEEE 1149.1). Timing it
# against the rising edge -- which the old all_outputs sweep effectively did,
# against the wrong clock entirely -- is simply wrong.
set_output_delay -mode func -clock jtag_tck -clock_fall $JTAG_IO_DELAY $JTAG_OUT


################################################################################
# 10. Drive and load
#
# Without these the tool assumes a zero-impedance driver and a zero load. That
# is why the old run reported in2reg slack of +4.06 ns: it was not real. Expect
# in2reg/reg2out to get WORSE after this change -- that is the constraint
# telling the truth for the first time.
################################################################################

# set_load only applies to the current corner and set_input_transition to the current scenario, and
# mcmm.tcl leaves the last one (fast) current when it sources this file. Applying them once here
# put the load and the input slew on fast only, so slow and typical, which size the outputs for
# setup and feed the exported SDC, saw zero load and an ideal input. Set them in every scenario.
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

# If your FC build rejects `-clock_path` on set_max_transition, drop that line
# and use the CTS-side option instead:
#     set_clock_tree_options -max_transition $MAX_TRAN_CLK


################################################################################
# 12. Sanity checks -- run these and READ them before trusting any QoR number
################################################################################

# report_clocks                    ;# expect 2 master clocks (clock, jtag_tck)
# check_timing                     ;# TCK-001 should collapse from 10,914 to
#                                  ;#   ~148 'case constant' (dead flops:
#                                  ;#   ibex imd_val_q_reg, OBI aid/rid tied to 0)
#                                  ;# TCK-002 should go to 0
# check_clock_trees                ;# CTS-905 / CTS-906 must both be 0
# report_clock_qor -type summary   ;# watch max latency and global skew
# report_constraint -all_violators