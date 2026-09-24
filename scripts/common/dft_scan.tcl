# Test I/O pins
set_dft_signal -view spec -type ScanDataIn  -port {jtag_tdi_i}
set_dft_signal -view spec -type ScanEnable  -port {jtag_tms_i} -active_state 1
set_dft_signal -view spec -type ScanDataOut -port {jtag_tdo_o}

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
# chosen specifically because it only de-asserts the reset during SCAN
# SHIFT, leaving the real functional reset path intact and testable during
# capture -- the mux method would permanently block the functional reset
# path, per the guide's own tradeoff table. Reusing the ScanEnable pin
# (jtag_tms_i) as the gate control signal needs no new pin.
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
set_autofix_configuration -type reset -method gate -control_signal {jtag_tms_i}
set_autofix_configuration -type set   -method gate -control_signal {jtag_tms_i}

###############################################################################
# 3b. ICG test-enable pin -- Clock Rule C1 fix attempt, tried 2026-08-18,
#     confirmed NOT to help, kept anyway (see caveat below for why)
###############################################################################
# Every gf180mcu_fd_sc_mcu7t5v0__icgtp_1 instance (this design's integrated
# clock gate -- 232 of them, confirmed to be exactly the same population as
# the 232 "DLAT" cells dft_drc's nonscan summary reports excluded from the
# flip-flop scan chain; the cell's own clock_gating_integrated_cell =
# "latch_posedge_precontrol" liberty attribute is why) has a dedicated TE
# (Test Enable) pin, unused until now, and was the prime suspect for the
# ~2936-cell Clock Rule C1 "unstable scan cells when clocks off" warning
# that AutoFix/lockup-latch/-clock_gating_init_cycles attempts didn't touch
# (see the caveat comment below section 4).
#
# Confirmed active-high directly from the liberty statetable
# (gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib, inputs "CLK E TE"):
#   L L L : - - : L H,   (CLK=0,E=0,TE=0 -> latched state = "disabled")
#   L H - : - - : H L,   (CLK=0,E=1        -> latched state = "enabled")
#   L - H : - - : H L,   (CLK=0,TE=1        -> SAME "enabled" state as E=1)
#   H - - : - - : N N    (CLK=1             -> latch holds, opaque)
# Row 3 shows TE=1 forces the identical latched state E=1 would, regardless
# of E's real value -- an active-high force-transparent override, exactly
# what DFT DRC's clocks-off simulation needs to prove deterministic.
#
# -control_signal only accepts the DFT signal TYPE keywords ScanEnable or
# TestMode (confirmed empirically -- a literal port name like testmode_i is
# rejected: "DFT-1024, only ScanEnable and TestMode are valid"). Used
# ScanEnable here since it was semantically the obvious choice and is
# already wired to jtag_tms_i above, needing no new signal declaration.
#
# RESULT (2026-08-18, full rebuild + fresh dft_drc): applied cleanly across
# all 232 instances (confirmed via report_dft_clock_gating_pin), but C1/C5/
# C8/C26/S22 came back byte-identical to before this section existed --
# 2936/27/17/48/1, totaling 3029 both times. Zero measurable effect.
#
# Leading theory for why: C1's "clocks off" scenario is a capture-mode
# check, and capture happens with ScanEnable DE-ASSERTED (shift is SE=1,
# capture is SE=0) -- tying TE to ScanEnable means TE=0 during exactly the
# window this check cares about, i.e. the bypass isn't actually active when
# it would matter. TestMode (the other valid -control_signal value, meant
# to stay asserted through the whole test session rather than toggle with
# shift/capture) is the more likely candidate, but no TestMode-type DFT
# signal exists in this flow yet (testmode_i is declared -type Constant, a
# different thing) and declaring one wasn't tried -- deliberately deferred
# rather than guessing again. Kept this section in place regardless: it's a
# real, verified-correct hardware declaration (the TE pin and its polarity
# are real, not a mistake), doesn't cost anything, and TestMAX ATPG will
# likely want this same clock-gating pin declared anyway once installed --
# see the ATPG readiness plan.
set icg_cells [get_cells -hierarchical -filter "ref_name == gf180mcu_fd_sc_mcu7t5v0__icgtp_1"]
puts "INFO: declaring TE pin on [sizeof_collection $icg_cells] icgtp_1 instances"
set_dft_clock_gating_pin -pin_name TE -active_state 1 -control_signal {ScanEnable} $icg_cells

###############################################################################
# 4. Insertion sequence (FC DFT User Guide Ch1 Figure 1 / Ch15 AutoFix flow)
###############################################################################
create_test_protocol

dft_drc
preview_dft
insert_dft -autofix

dft_drc
preview_dft
insert_dft

# KNOWN, DOCUMENTED CAVEAT (2026-08-17, updated 2026-08-18): post-insertion
# dft_drc still reports Clock Rule C1 (unstable scan cells when clocks off)
# on ~74% of the ~3964 scanned cells, plus smaller C5/C8/C26 counts.
# Attempts tried and CONFIRMED not to move any of these numbers:
#   - clock mixing (rerun with two unmixed per-domain chains -- identical
#     violation count)
#   - lock-up element: flip-flop instead of latch
#   - -clock_gating_init_cycles (documented fix for a different, narrower
#     clock-gating-latch-at-time-zero scenario)
#   - declaring the ICG TE pin via set_dft_clock_gating_pin, control signal
#     ScanEnable (section 3b above) -- applied cleanly, byte-identical
#     result. Leading theory: capture happens with ScanEnable de-asserted,
#     so tying TE to ScanEnable leaves it inactive during exactly the
#     window C1 checks. TestMode (the only other valid control signal) is
#     untried -- no TestMode-type DFT signal exists in this flow yet.
# The most likely remaining cause is still this design's pervasive
# integrated clock-gating cells interacting with DFT DRC's "simulate with
# every clock PI off" check in a way not fully resolved here.
#
# Practical read: C1/C5/C8/C26 are about CAPTURE-mode stability (matters
# for formal, automated ATPG pattern generation -- TestMAX and friends),
# not SHIFT-mode operation. The chain itself is built and DRC-clean on the
# rules that actually gate scan-chain INCLUSION (D1-D17): all ~3964
# eligible flops are in the chain. For the bring-up use case this exists
# for -- freeze the chip, shift the current flop state out (or a chosen
# state in) over jtag_tdi_i/jtag_tms_i/jtag_tdo_o -- that should work as-is.
# Getting a clean, ATPG-signoff-grade C1 result is future work: try a
# TestMode-type control signal next, or lean on TestMAX's own DRC/
# diagnosis once installed for better visibility into the actual cause.
dft_drc
