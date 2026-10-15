###############################################################################
# scripts/common/dft_scan.tcl -- basic internal scan chain configuration
#
# Sourced from scripts/03_synthesis.tcl between `compile_fusion -to
# logic_opto` and `compile_fusion -from initial_place -to initial_opto`,
# matching the FC DFT User Guide's recommended in-compile flow (Ch1,
# Figure 1): set_scan_configuration/set_dft_signal -> create_test_protocol
# -> dft_drc -> preview_dft -> insert_dft -> dft_drc.
#
# Scope, deliberately: ONE plain internal (multiplexed flip-flop) scan
# chain. No compression, no core wrapping, no on-chip clocking, no test
# points, no LBIST/MBIST/SRAM BIST -- this exists purely so a bring-up
# engineer can freeze the chip and shift the full flop state in/out over a
# handful of pins, which is the single highest-value, lowest-complexity
# debug tool available before knowing what's actually wrong.
###############################################################################

###############################################################################
# 1. Test I/O pins -- dedicated ports
###############################################################################
# One scan chain, three dedicated ports (created in 01_read_rtl.tcl; the
# RTL has no scan ports):
#   scan_si_i -> ScanDataIn   scan_se_i -> ScanEnable   scan_so_o -> ScanDataOut
# An earlier revision shared gpio_i[0]/gpio_i[1]/gpio_o[0] with the scan
# signals. FC inserted the muxing, but gpio_i[1] then drove every scan flop's
# SE and the reset/set gating, so any 1 on that GPIO input in normal operation
# put the flops into scan mode. With dedicated ports the functional GPIOs are
# untouched and scan_se_i is tied to 0 outside test (mode_func.tcl).
set_dft_signal -view spec -type ScanDataIn  -port {scan_si_i}
set_dft_signal -view spec -type ScanEnable  -port {scan_se_i} -active_state 1
set_dft_signal -view spec -type ScanDataOut -port {scan_so_o}

###############################################################################
# 2. Clocks and reset
###############################################################################
# Both existing functional clock ports are reused directly as scan shift
# clocks -- no dedicated test clock pin needed, just pulse clk_i (or
# jtag_tck_i for the JTAG-domain flops) with ScanEnable held high to shift.
#
# The -timing {rise fall} values are NOT real hardware timing -- they are
# positions within FC's own dft.test_default_period (100ns, shared by every
# test clock regardless of real period) used purely to order scan cells
# and place lock-up latches correctly (DFT User Guide Ch3, "Requirements
# for Valid Scan Chain Ordering"). clk_i and jtag_tck_i are given
# non-overlapping windows so ordering is unambiguous; the real chip is
# still driven at whatever rate the bring-up setup chooses.
set_dft_signal -view existing_dft -type ScanClock -port clk_i      -timing {50 70}
set_dft_signal -view existing_dft -type ScanClock -port jtag_tck_i -timing {75 90}

set_dft_signal -view existing_dft -type Reset -port rst_ni -active_state 0

# testmode_i is left case-analysis'd to 0 for functional signoff elsewhere
# in this flow (mode_func.tcl), but for DFT DRC's own clocks-off simulation
# it must be pinned to a known value too: it's the select line on the
# tc_clk_mux2 cells inside rtl/common_cells/rstgen_bypass.sv (the reset
# synchronizer's own test bypass mux). Left unconstrained here, DFT DRC's
# "Clock Rule C1" (unstable scan cells when clocks off) fires broadly
# because that mux's select is undetermined during the check. This is
# exactly the documented C1 root cause ("a clock which passes through a MUX
# whose select line is not constant... should be constrained") -- confirmed
# 2026-08-17: adding this constraint dropped D3 (reset line not
# controlled) from 3649 to 2885 pre-AutoFix.
set_dft_signal -view spec -type Constant -port testmode_i -active_state 1
# The same port again as a TestMode signal for AutoFix: the control signal of set_autofix_configuration
# must be declared as -type TestMode -usage autofix (or as a ScanEnable); a plain Constant is rejected (DFT-1964).
set_dft_signal -view spec -type TestMode -usage autofix -port testmode_i -active_state 1

set_scan_configuration -chain_count 1 -clock_mixing mix_clocks

###############################################################################
# 3. AutoFix -- reset synchronizer controllability
###############################################################################
# Most of this design's flops are reset by synced_rst_n, generated inside
# i_rstgen from rst_ni through a 4-stage synchronizer (rtl/common_cells/
# rstgen_bypass.sv) -- not by the rst_ni PRIMARY INPUT directly. DFT DRC
# can't prove a synchronized/generated reset is controllable within a scan
# cycle (confirmed 2026-08-17: this alone was responsible for 3649 "DFF
# reset line not controlled" / D3 violations, and ~83 "DFF set line not
# controlled" / D2 violations, on a design with ~4000 total flops -- i.e.
# nearly everything). rstgen_bypass.sv already has a test_mode_i-controlled
# bypass path, but declaring testmode_i as a DFT signal (section 2 above)
# did NOT make DFT DRC trace through it for controllability purposes --
# TestMode/Constant signal declarations appear to only feed Formality SVF
# generation, not DFT DRC's own reset-controllability analysis.
#
# AutoFix is the tool's purpose-built answer: it inserts real gating logic
# directly at each uncontrollable reset/set pin. -method gate (vs. mux) was
# chosen because it leaves the functional reset path in place when the
# control signal is inactive (the mux method would permanently block it,
# per the guide's own tradeoff table). The gate control signal is
# testmode_i, which is high in every test state, so the resets are held
# inactive during shift AND capture and while the clocks are off. With
# scan_se_i as the control signal the resets were held inactive only while
# scan_se_i was 1, and Clock Rule C1 fired 2936 times (see below).
#
# Confirmed 2026-08-17: this dropped D2/D3 to 0 and D15 (a downstream
# consequence of D3) from 3539 to 0 as well, leaving only D10 (48, a
# residual clock-vs-data classification warning on the same
# tc_clk_mux2/tc_clk_inverter cells, not reset-related) and D1 (1).
#
# AutoFix requires TWO insert_dft passes (documented limitation): first
# -autofix alone to insert the gating logic, then a plain insert_dft for
# the actual scan chain stitching -- see step 4.
set_dft_configuration -fix_reset enable
set_dft_configuration -fix_set enable
set_autofix_configuration -type reset -method gate -control_signal {testmode_i}
set_autofix_configuration -type set   -method gate -control_signal {testmode_i}

###############################################################################
# 4. Insertion sequence (FC DFT User Guide Ch1 Figure 1 / Ch15 AutoFix flow)
###############################################################################
