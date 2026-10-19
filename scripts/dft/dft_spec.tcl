###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: DFT signal declarations for the STIL export (export_stil.tcl)
###############################################################################

# Sections 1 to 3 of scripts/common/dft_scan.tcl, without the insertion. Keep the two files the same.

###############################################################################
# 1. Test I/O pins
###############################################################################
# Dedicated ports (created in 01_read_rtl.tcl). Shared GPIOs put the flops into scan mode when the GPIO
# input was 1 in normal operation. mode_func.tcl ties scan_se_i to 0.
set_dft_signal -view spec -type ScanDataIn  -port {scan_si_i}
set_dft_signal -view spec -type ScanEnable  -port {scan_se_i} -active_state 1
set_dft_signal -view spec -type ScanDataOut -port {scan_so_o}

###############################################################################
# 2. Clocks and reset
###############################################################################
# The functional clocks shift the chain. The -timing values are positions in FC's 100 ns test period, not real
# timing: the two windows do not overlap, so FC can order the cells and place the lock-up latches.
set_dft_signal -view existing_dft -type ScanClock -port clk_i      -timing {50 70}
set_dft_signal -view existing_dft -type ScanClock -port jtag_tck_i -timing {75 90}

set_dft_signal -view existing_dft -type Reset -port rst_ni -active_state 0

# testmode_i selects the bypass mux of the reset synchronizer (rstgen_bypass.sv). DFT DRC needs it constant,
# else Clock Rule C1 fires on the flops behind that mux.
set_dft_signal -view spec -type Constant -port testmode_i -active_state 1
# The same port as the AutoFix control signal: AutoFix accepts only a TestMode or ScanEnable signal (DFT-1964).
set_dft_signal -view spec -type TestMode -usage autofix -port testmode_i -active_state 1

set_scan_configuration -chain_count 1 -clock_mixing mix_clocks

###############################################################################
# 3. AutoFix of the reset and set pins
###############################################################################
# Most flops are reset through the 4-stage synchronizer of i_rstgen, which DFT DRC cannot control in a scan
# cycle (D2/D3 on almost every flop). AutoFix gates each reset and set pin with testmode_i. The gate method
# keeps the functional reset path when testmode_i is 0. testmode_i is 1 in every test state, so the resets
# stay inactive in shift, in capture and with the clocks off (Clock Rule C1, AUS-15). Cost: ATPG cannot test
# the reset paths.
set_dft_configuration -fix_reset enable
set_dft_configuration -fix_set enable
set_autofix_configuration -type reset -method gate -control_signal {testmode_i}
set_autofix_configuration -type set   -method gate -control_signal {testmode_i}
