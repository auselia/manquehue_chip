# -----------------------------------------------------------------------------
# This file was created at the Institute of Microelectronic Systems,
# Leibniz University Hannover. It is provided "as is" without
# warranty of any kind, express or implied, including but not
# limited to correctness or fitness for a particular purpose.
#
# Author: Viktor Schneider
# -----------------------------------------------------------------------------

source [file dirname [info script]]/common/open_lib.tcl
open_block floorplan

###########################################################
# QOR settings
###########################################################


set_app_options -name ccd.max_prepone -value 2.4
set_app_options -name ccd.max_postpone -value 0.8

# configure initial subset of cells for synthesis
set_lib_cell_purpose -include none [get_lib_cells $SYN_IGNORE_CELLS]


###############################################################################
# Synthesis MEGA COMMAND
###############################################################################
# Enables FC's own verification checkpointing (ckpt_pre_map + ckpt_logic_opt,
# the default pair) during compile_fusion: it snapshots the design at those
# stages and records the guide_checkpoint transformation history to an .svf
# file, which the Formality tool can then use to correlate this RTL and the
# resulting gate netlist directly instead of matching from scratch. Added
# 2026-08-15 because a plain (non-SVF) Formality RTL-vs-gate run against a
# prior build got stuck at ~99% "Unverified" compare points -- root-caused
# (via analyze_points) to a reset-synchronizer register Formality's own
# structural analysis couldn't resolve without FC's own transformation
# record. See scripts/fm/lec_rtl_vs_gate.tcl and the Fusion Compiler User
# Guide's "Generating Verification Checkpoints During Compilation" section.
set_verification_checkpoints

# Split into two compile_fusion calls with DFT scan insertion sandwiched in
# between, matching the FC DFT User Guide's recommended "in-compile flow"
# (Ch1, Figure 1) exactly -- this is the officially unified, better-QoR path
# vs. inserting scan as a bolt-on afterthought, and it's a straight
# replacement for the single unstaged `compile_fusion` call this used to be.
compile_fusion -to logic_opto

###############################################################################
# Basic internal scan chain insertion (added 2026-08-17)
###############################################################################
# Why: for chip bring-up debug -- being able to freeze the design and shift
# out every flip-flop's state (or shift a known state in) is the single most
# useful, most generic observability tool available before real silicon
# comes up, independent of whatever the actual bug turns out to be.
# Deliberately minimal: one plain internal (multiplexed flip-flop) scan
# chain, no compression (DFTMAX/DFTMAX Ultra), no core wrapping, no on-chip
# clocking, no test points, no LBIST/MBIST/SRAM BIST. See
# scripts/common/dft_scan.tcl for the full commented derivation of every
# choice below (pin reuse, AutoFix, why single-chain, the known capture-mode
# caveat) -- this file just sources it at the right point in the flow.
source [file dirname [info script]]/common/dft_scan.tcl

# Resumes compile_fusion from where DFT insertion left the design (adds new
# scan mux/AutoFix-gate/lock-up-latch cells that need to be placed and
# logic-optimized in) through to the same final stage a plain, unstaged
# `compile_fusion` call would have reached. This exact stage pairing
# (-to logic_opto / DFT insertion / -from initial_place -to initial_opto) is
# what FC DFT User Guide Figure 1 shows as the complete in-compile sequence.
compile_fusion -from initial_place -to initial_opto

set ACTIVE_STEP "03_synthesis"
source [file dirname [info script]]/common/reporting.tcl

save_block -as synthesis
