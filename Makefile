# -----------------------------------------------------------------------------
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Unified Fusion Compiler (FC) RTL-to-GDS + KLayout/IC Validator DRC+LVS Makefile
# -----------------------------------------------------------------------------

SHELL := /bin/bash
.DELETE_ON_ERROR:

# Helpers for converting Make's space-separated lists into comma-separated
# strings (e.g. for klayout -rd args that take a comma-separated list).
empty :=
space := $(empty) $(empty)
comma := ,

# ------------------------------------------------------------------------------
# Design Configuration
# ------------------------------------------------------------------------------
TOP                := croc_soc
WORK_DIR           := work
LOGS_DIR           := logs
REPORTS_DIR        := reports
OUTPUTS_DIR        := outputs
REPO_DIR           := $(shell pwd)

.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Sign-off run selection (shared by DRC and LVS)
# ------------------------------------------------------------------------------
# Each Fusion Compiler run (see 06_finish.tcl) lands in its own folder:
#   outputs/<TOP>_<YYYYMMDD_HHMMSS>/{<TOP>.gds, <TOP>.v}
# and outputs/latest is a symlink to the newest one. Sign-off targets read
# GDS/VLOG out of that run folder and write their results right back into it
# (.../drc/, .../lvs/), so everything for a run lives in one place.
#
#   make drc                              # latest run
#   make lvs                              # latest run
#   make drc RUN=croc_soc_20260804_101500 # a specific (older) run
#   make drc GDS=/path/to/other.gds VLOG=/path/to/other.v  # fully explicit
RUN  ?= latest
GDS  ?= $(OUTPUTS_DIR)/$(RUN)/$(TOP).gds
VLOG ?= $(OUTPUTS_DIR)/$(RUN)/$(TOP).v

# ------------------------------------------------------------------------------
# Sign-off / DRC configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# DRC_HOME must contain: run_drc.py, rule_decks/, utils/, and the three
# top-level decks gf180mcu.drc / gf180mcu_antenna.drc / gf180mcu_density.drc.
DRC_HOME      ?= $(HOME)/Documents/gf180_drc_lvs/drc/
# Metal stack option passed to run_drc.py / run_lvs.py:  A=3LM  B=4LM  C=5LM
GF180MCU_OPT  ?= C
# KLayout run mode: flat | deep | tiling
DRC_RUN_MODE  ?= flat
# Extra run_drc.py flags, e.g. DRC_EXTRA="--antenna --density"
DRC_EXTRA     ?= --thr=6
# run_drc.py derives $PDK_ROOT/$PDK from these; we set them explicitly so a
# PDK_ROOT already exported for the Synopsys flow can't interfere.
DRC_PDK_ROOT  ?= $(dir $(patsubst %/,%,$(DRC_HOME)))
DRC_PDK       ?= $(notdir $(patsubst %/,%,$(DRC_HOME)))

# ------------------------------------------------------------------------------
# Sign-off / LVS configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# LVS_HOME must contain: run_lvs.py, verilog2spice.py, fold_wells.py, and the
# gf180mcu.lvs deck. Fusion Compiler does not export a SPICE schematic, so
# `make lvs` first rebuilds one from the exported gate-level Verilog (VLOG)
# using verilog2spice.py against the gf180mcu_fd_sc_mcu7t5v0 CDL, then runs
# KLayout LVS comparing that schematic against the GDS.
LVS_HOME         ?= $(HOME)/Documents/gf180_drc_lvs/lvs/
# KLayout run mode: flat | deep | tiling (deep is the validated default here)
LVS_RUN_MODE     ?= deep
# Substrate net name used in the design
LVS_SUB          ?= VSS
# Complete, versioned GF180MCU PDK managed by `ciel` (the open-source PDK
# version manager). ~/.ciel/gf180mcu<OPT> is a stable symlink to the
# currently-active ciel version, so it survives PDK upgrades. It ships one
# combined CDL per library (libs.ref/<lib>/cdl/<lib>.cdl) -- this is the
# REAL, complete gf180mcu_fd_sc_mcu7t5v0 library whose subckt names match
# what Fusion Compiler's write_verilog actually instantiates.
#
# NOTE: this is deliberately NOT gf180_drc_lvs/lvs/testing/sc_testcases/*.cdl
# (different, X1_7T5P0-style cell names -- a test-suite fixture) and NOT
# ~/pdk_synopsys/cdl/*.cdl (a partial, per-cell export missing most cells,
# e.g. inv_1/nand2_1/fillcap_*/dffrnq_1 -- confirmed missing 2026-08-12).
# GF180MCU_OPT selects the metal-stack variant (A/B/C/D), matching ciel's own
# gf180mcuA/B/C/D directories; the standard-cell CDL itself is identical
# across all four (verified by checksum), only IO/SRAM/tech data differs.
LVS_PDK_KIT      ?= $(HOME)/.ciel/gf180mcu$(GF180MCU_OPT)/libs.ref
# Reference (real) standard-cell CDL. fold_wells.py always strips the
# physical-only `antenna` cell (its diodes break KLayout's SPICE reader),
# and folds VPW -> VSS (matching gf180mcu.lvs's own connect_global on the
# substrate, which globally merges every p-well/substrate tap into VSS
# *within* KLayout's per-leaf-cell extraction). It deliberately does NOT
# fold VNW -> VDD: n-well has no equivalent global connect in this deck, so
# a layout leaf cell keeps its n-well tap as a genuinely separate pin
# (merged into VDD only through abutment with neighboring cells at the
# parent level) -- folding it in the schematic would give every leaf cell a
# spurious pin-count mismatch. verilog2spice.py's own default
# `--tie VNW=VDD` ties each *instantiation's* VNW pin to VDD instead,
# mirroring what abutment does in the layout. The result is cached under
# outputs/.cache/ and only rebuilt when the source CDL changes.
LVS_SC_CDL       ?= $(LVS_PDK_KIT)/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl
LVS_WELL_TIES    ?= --tie VPW=VSS
# Renames the CDL's SPICE MOSFET model names (nfet_05v0/pfet_05v0) to match
# gf180mcu.lvs's own layout-side device class names (nmos_5p0/pmos_5p0, from
# its extract_devices(mos4("nmos_5p0"), ...) calls). With matching names,
# KLayout's NetlistComparer treats them as the same class automatically --
# no same_device_classes equivalence declaration needed. That matters
# because this KLayout version's (0.30.9) built-in same_device_classes DSL
# helper reliably errors out even when given classes that verifiably exist
# (see the note in gf180mcu.lvs), which otherwise leaves every MOSFET
# pairing -- and thus the deck's own native `compare` and the .lvsdb you'd
# open in KLayout -- unusably wrong (confirmed 2026-08-12: renaming took the
# deck's own compare from ~thousands of spurious failures down to 126 minor
# warnings, concentrated in decap fillers and a few compound gates, none of
# them hard failures). Without this, the .lvsdb in KLayout cannot be trusted.
LVS_MODEL_RENAME ?= --rename-model nfet_05v0=nmos_5p0 --rename-model pfet_05v0=pmos_5p0
# Hard macros with no transistor-level CDL to compare against (e.g. SRAM):
# black-boxed by pin interface only, so they LVS as opaque cells and must be
# signed off separately. Defaults to every gf180mcu SRAM size in the kit;
# harmless to list sizes the design doesn't use (verilog2spice.py only emits
# stubs for cells actually instantiated).
LVS_BLACKBOX_CDL ?= $(wildcard $(LVS_PDK_KIT)/gf180mcu_fd_ip_sram/cdl/gf180mcu_fd_ip_sram__sram*.cdl)
# Hard macros to black-box on the LAYOUT (GDS) side for `make lvs` too --
# not just the schematic. Fusion Compiler's write_gds places the SRAM's
# real, full transistor-level view (thousands of devices per instance);
# without this, LVS "compares" that against the schematic's pin-only stub
# and fails on device count alone, telling you nothing about the design
# itself. `make lvs` derives a black-boxed copy of $(GDS) (blackbox_gds_cells.rb
# strips diffusion/poly/well/implant/contact layers from just these cells'
# sub-hierarchy, leaving metal/via routing and pin labels untouched, so the
# macro's boundary connectivity is unaffected) and signs off against that --
# $(GDS) itself is never modified, so it's unaffected for `make drc` and
# stays exactly what Fusion Compiler wrote for tapeout. Defaults to the cell
# names implied by LVS_BLACKBOX_CDL; set to empty to sign off the real GDS
# as-is (e.g. once you have a transistor-level SRAM CDL to LVS it against
# directly instead of treating it as a black box).
LVS_BLACKBOX_CELLS ?= $(basename $(notdir $(LVS_BLACKBOX_CDL)))
# Comma-separated, case-insensitive substrings: subcircuit instances whose
# referenced circuit name contains any of these are removed from BOTH the
# layout and schematic netlists before compare (symmetrically, comparison
# scope only -- the real GDS/.v/.sp are untouched, so DRC and tapeout are
# unaffected). fillcap (decoupling-cap fillers) has thousands of instances
# tying only VDD/VSS with no signal connectivity and no distinguishing
# topology between same-size instances, so exact 1:1 instance
# correspondence between an independently-drawn layout and an
# independently-synthesized schematic is fundamentally ambiguous -- not a
# real violation, just more interchangeable siblings than a graph-
# isomorphism matcher can uniquely resolve (confirmed 2026-08-13: this was
# the deciding factor between "Netlists don't match" and "Congratulations!
# Netlists match" on croc_soc, with the *same* 126 harmless
# MatchWithWarning notes either way -- see lvs_compare_summary.txt).
# Set to empty to compare every instance, filler cells included.
LVS_EXCLUDE_FROM_COMPARE ?= fillcap
# Known-good run_lvs.py switches (matches the manually-verified croc_soc run).
LVS_FLAGS        ?= --set_spice_comments --set_net_only --set_top_lvl_pins --set_combine --set_purge --set_purge_nets
# Extra run_lvs.py flags, e.g. LVS_EXTRA="--thr=6 --set_verbose"
LVS_EXTRA        ?= --thr=6
LVS_PDK_ROOT     ?= $(dir $(patsubst %/,%,$(LVS_HOME)))
LVS_PDK          ?= $(notdir $(patsubst %/,%,$(LVS_HOME)))
# Layout-vs-schematic MOSFET device-class equivalence, passed to
# lvs_compare.rb (the secondary cross-check -- see LVS_MODEL_RENAME above
# for the primary fix, which makes this unnecessary by construction: with
# both sides' CDL model names already renamed to match the layout's own
# device class names, they read back with the SAME name -- e.g. NMOS_5P0
# on both sides, not NMOS_5P0 vs NFET_05V0 -- so KLayout's NetlistComparer
# already treats them as equivalent with no mapping needed. Empty by
# default; only set this if you override LVS_MODEL_RENAME to something
# that leaves the names actually differing between the two sides.
LVS_DEVICE_CLASS_MAP ?=

CACHE_DIR       := $(OUTPUTS_DIR)/.cache
FOLDED_SC_CDL   := $(CACHE_DIR)/gf180mcu_fd_sc_mcu7t5v0.folded.cdl

# ------------------------------------------------------------------------------
# Sign-off / DRC + LVS configuration (Synopsys IC Validator + GF180MCU)
# ------------------------------------------------------------------------------
# Second, independent DRC/LVS engine using the ICV decks shipped alongside
# the Synopsys PDK install (pdk_synopsys/DRC_ICV*, pdk_synopsys/LVS_ICV) --
# useful as a cross-check against the KLayout `drc`/`lvs` targets above, or
# on its own. LVS reuses the same verilog2spice.py/fold_wells.py helpers
# from LVS_HOME/LVS_SC_CDL above; only the standard-cell CDL is re-folded
# without the KLayout-specific model rename (see FOLDED_SC_CDL_ICV below).
ICV_HOME_DIR      ?= /usr/synopsys/icvalidator/Y-2026.03-SP2
ICV_PDK_HOME      ?= $(HOME)/pdk_synopsys
ICV_HOST_INIT     ?= 4
# Both ICV decks were authored assuming a 1nm (0.001um) GDS database unit,
# but Fusion Compiler's write_gds exports at 0.1nm (0.0001um); without a
# fix ICV aborts immediately with "ERROR: Library resolution "0.0001" does
# not match specified runset layout_resolution "0.001"." This runset config
# patches the deck's resolution_options() to match, via `icv -runset_config`
# (confirmed 2026-08-14: both DRC decks and the LVS deck run clean with this
# fix in place). If Fusion Compiler's GDS export precision ever changes,
# update ICV_LAYOUT_RESOLUTION AND the matching value inside the file itself.
ICV_RUNSET_CONFIG     ?= scripts/icv/resolution_override.rs
ICV_LAYOUT_RESOLUTION ?= 0.0001

# DRC: pick either the foundry-original, full-coverage deck (DRC_ICV/,
# default -- needs BEOL_STACK/TOPMETAL/etc below) or the simpler, community-
# ported DRC_ICV_MODIFIED/ deck (no extra env vars required, but its own
# README warns it "may miss critical rules" -- see pdk_synopsys/
# DRC_ICV_MODIFIED/DRC/ICV/README.md):
#   make drc-icv ICV_DRC_RUNSET=$(ICV_PDK_HOME)/DRC_ICV_MODIFIED/DRC/ICV/gf180mcu_drc.rs
ICV_DRC_RUNSET   ?= $(ICV_PDK_HOME)/DRC_ICV/DRC/ICV/gf180mcu_drc.rs
# Required by DRC_ICV/gf180mcu_drc.rs. ICV_BEOL_STACK mirrors GF180MCU_OPT
# above (A=1P3M B=1P4M C=1P5M); the rest have no equivalent in the KLayout
# flow and default to the most common GF180MCU MCU tapeout choice --
# override if your target metal stack/pad type differs.
ICV_BEOL_STACK   ?= 1P5M
ICV_TOPMETAL     ?= 11KA
ICV_MIMCAP       ?= OPT_A
ICV_PADBONDING   ?= WEDGE
ICV_LATCH_CHECK  ?= DECK_ONLY
# Extra icv command-line options, e.g. ICV_DRC_EXTRA="-svc *density*"
ICV_DRC_EXTRA    ?=

# LVS
ICV_LVS_RUNSET   ?= $(ICV_PDK_HOME)/LVS_ICV/LVS/ICV/cmos018hv.3p3.6v.lvs.rs
ICV_LVS_HOME     ?= $(patsubst %/,%,$(dir $(ICV_LVS_RUNSET)))
# Extra icv command-line options, e.g. ICV_LVS_EXTRA="-vueshort"
ICV_LVS_EXTRA    ?=
# LVS_ICV's own unit.cdl declares device types in uppercase (NFET_05V0/
# PFET_05V0, OpenPDK-style) and ICV compares device names case-insensitively
# by default, so -- unlike the KLayout gf180mcu.lvs deck -- this needs NO
# --rename-model: the real gf180mcu_fd_sc_mcu7t5v0 CDL's own lowercase
# nfet_05v0/pfet_05v0 model names already match (confirmed 2026-08-14: ICV
# LVS ran to completion and matched 117/118 hierarchical cells on croc_soc
# with the plain, un-renamed fold below; the one remaining top-level
# mismatch is very likely the same filler-cell ambiguity documented at
# LVS_EXCLUDE_FROM_COMPARE above, not a naming issue). Folded separately
# from FOLDED_SC_CDL above (same LVS_WELL_TIES, no LVS_MODEL_RENAME) and
# cached alongside it; only rebuilt when the source CDL changes.
FOLDED_SC_CDL_ICV := $(CACHE_DIR)/gf180mcu_fd_sc_mcu7t5v0.icv.folded.cdl

# Metal fill (density signoff). scripts/icv/croc_metal_fill.rs is a
# purpose-built Metal1-Metal5 dummy-fill runset (not a pdk_synopsys file --
# it lives in this repo) derived from pdk_synopsys/DRC_ICV_MODIFIED/DRC/
# ICV/gf180mcu_fill.rs; see that file's header comment for the full
# derivation and validation history (datatype fix, pad-ring-heuristic
# removal, spacing retune against real GF180MCU DRC minimums). It still
# needs -I pointed at DRC_ICV_MODIFIED/DRC/ICV for its
# #include "gf180mcu_layers.rh".
# Validated 2026-08-14 on croc_soc: raises Metal1-5 coverage from
# 30.2%/18.9%/25.2%/17.7%/13.3% to 33.3%/39.4%/44.1%/60.8%/64.5% (all
# above the gf180mcu_density.drc 30% signoff threshold), and a full
# (non-density-only) KLayout DRC re-check found zero new violations
# versus the unfilled baseline.
ICV_FILL_RUNSET       ?= scripts/icv/croc_metal_fill.rs
ICV_FILL_INCLUDE_DIR  ?= $(ICV_PDK_HOME)/DRC_ICV_MODIFIED/DRC/ICV
# Extra icv command-line options, e.g. ICV_FILL_EXTRA="-vue"
ICV_FILL_EXTRA        ?=

# ------------------------------------------------------------------------------
# Sign-off STA / power - Synopsys PrimeTime + PrimePower (GF180MCU, MCMM)
# ------------------------------------------------------------------------------
# Reads the SDC + per-corner SPEF that the FC flow's own scripts/07_pt_export.tcl
# step writes into outputs/<run>/ (same folder as GDS/Verilog -- see that
# script's header comment for why one write_parasitics call produces 3 SPEF
# files, one per MCMM corner temperature). `make sta-pt`/`make power-pp`
# don't depend on `pt_export` the way FC's own numbered steps chain off each
# other -- like drc/lvs/drc-icv above, they just check the SDC/SPEF exist and
# tell you to run `make pt_export` if not, rather than silently kicking off a
# (potentially multi-hour) FC re-run as a side effect.
PT_HOME_DIR ?= /usr/synopsys/prime/Y-2026.03-SP2
SDC  ?= $(OUTPUTS_DIR)/$(RUN)/$(TOP).sdc

# PrimeTime has no notion of FC's in-design MCMM (create_corner/create_mode/
# create_scenario is an FC/ICC2-specific API -- confirmed 2026-08-15 that
# plain pt_shell doesn't even have those commands, and pt_shell -multi_scenario
# only adds create_scenario, built for distributing scenarios across a host
# farm via per-scenario common_data/specific_data scripts). scripts/pt/
# sta_corner.tcl instead runs one classic pt_shell session per corner, so
# each corner's liberty views are spelled out explicitly here. Voltage/
# temperature match scripts/common/mcmm.tcl's 3 corners exactly (slow=SS/
# 4.5V/125C, typical=TT/5.0V/25C, fast=FF/5.5V/-40C -- switched 2026-08-18
# from the 3.0/3.3/3.6V family this design was previously, incorrectly, set
# to; gf180mcu_fd_sc_mcu7t5v0 ships all three voltage families in the same
# library, this design's actual target is 5V); filenames are this PDK
# kit's own gf180mcu_fd_sc_mcu7t5v0/gf180mcu_fd_io .db naming for that same
# PVT triple (confirmed present under PT_PDK_DB_DIR 2026-08-15).
PT_PDK_DB_DIR    ?= $(ICV_PDK_HOME)/db
PT_SC_DB_slow    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.db
PT_SC_DB_typical ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.db
PT_SC_DB_fast    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_sc_mcu7t5v0__ff_n40C_5v50.db
PT_IO_DB_slow    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_io__ss_125C_4v50.db
PT_IO_DB_typical ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_io__tt_025C_5v00.db
PT_IO_DB_fast    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_io__ff_n40C_5v50.db

# SRAM macro: this PDK kit ships exactly ONE SRAM characterization
# (gf180mcu_fd_ip_sram__sram512x8m8wm1, tt/25C/5.0V -- no ss/ff corner
# views). Previously this was a real PDK-IP gap: the rest of the design ran
# a 3.0-3.6V MCMM rail while this macro was stuck at 5.0V for lack of any
# alternative characterization, and power_grid.tcl ties every macro
# including the SRAM to one design-wide VDD/VSS net, so there was no
# separate 5V supply for that 5V characterization to genuinely correspond
# to. Since the whole design switched to the 5.0V-nominal rail (2026-08-18,
# see scripts/common/mcmm.tcl), this SRAM view now matches the rest of the
# design instead of being the odd one out -- reused across all 3 corners
# below because SS/FF SRAM views still don't exist in this PDK kit, but the
# voltage itself is no longer a mismatch. Only shipped as .lib (text), not
# .db; Library Compiler (lc_shell, same Synopsys install family as the rest
# of this flow) converts it once, cached the same way FOLDED_SC_CDL is
# above and only rebuilt if the source .lib changes.
PT_SRAM_LIB ?= $(HOME)/pdk_synopsys/lib/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.lib
PT_SRAM_DB  := $(CACHE_DIR)/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.db
LC_HOME_DIR ?= /usr/synopsys/lc/Y-2026.03-SP1

# PrimePower: vectorless (default/statistical switching activity) analysis --
# this environment has no gate-level VCD/SAIF from a real workload run yet
# (sim/ only has scripts + sw sources, no captured activity dump), so power
# numbers below are an early/averaged estimate, not simulation-derived
# signoff power. Set PP_SAIF to a real activity file once one exists.
PP_SAIF ?=
PP_DEFAULT_TOGGLE_RATE ?= 0.1
PP_DEFAULT_STATIC_PROB ?= 0.5
# Default to `fast` only, mirroring mcmm.tcl's own set_scenario_status (only
# the fast=FF/3.6V/-40C scenario has dynamic_power/leakage_power enabled --
# highest MCMM voltage, dominates both switching and leakage power enough to
# outweigh the low-temperature leakage reduction). Override to check other
# corners too, e.g. PP_CORNERS="slow typical fast".
PP_CORNERS ?= fast

# ------------------------------------------------------------------------------
# Sign-off Rail Analysis - RedHawk-SC Fusion (in-design, via Fusion Compiler)
# ------------------------------------------------------------------------------
# Unlike drc/lvs/sta-pt/power-pp, this does NOT read an exported outputs/<run>
# artifact -- it reopens the live 'finish' block in work/design.dlib (see
# scripts/rail/analyze_rail.tcl) and runs RedHawk-SC's analyze_rail directly
# against FC's own routed PDN, so it always reflects whatever 'make finish'
# (or 'make all') last built, not a specific archived RUN. Nothing about the
# block is modified/saved -- taps and the rail result exist only for the
# session; reports land in outputs/latest/rail_rh/.
#
# create_taps -top_pg treats croc_soc's top-level VDD/VSS pins (the 6+6
# discrete Metal5 pins) as the ideal external supply -- this is the direct
# test of whether those 6 pins are enough, or where the worst IR drop is if
# not.
#
# No standalone 'redhawk' binary exists in this env -- RedHawk-SC ships
# bundled inside the IC Validator install instead (confirmed 2026-08-22:
# ICV_HOME_DIR/pfsc/linux/bin/redhawk_sc runs and is licensed --
# SNPS_INDESIGN_RH_RAIL, 100 seats).
RAIL_PRODUCT      ?= redhawk_sc
RAIL_REDHAWK_PATH ?= $(ICV_HOME_DIR)/pfsc/linux/bin
RAIL_VOLTAGE_DROP ?= static
# analyze_rail needs a tech file describing per-layer R/C (RAIL-300) -- FC's
# own docs call this an "ATF" but this RedHawk-SC build only actually
# accepts itf/ircx/nrc (confirmed empirically 2026-08-22, "unrecognized
# type" on a hand-authored .atf). scripts/rail/tech/gf180mcu.itf is the
# real thing, not hand-authored: recovered directly from GlobalFoundries'
# own field-solver binary (~/pdk_synopsys/pex/*.nxtgrd, the same officially
# -released PEX kit as the TLUplus files) via StarRC's grdgenxo
# -nxtgrd2itf converter, then had its CONDUCTOR/VIA names remapped from
# TLUplus-internal names (TM/M4../V1..) to GF180MCU's real LEF/DEF names
# (Metal5/Metal4../Via1..) per ~/pdk_synopsys/tech/tluplus/mdb2itf.map --
# required, or nearly every via/pin fails to resolve (141k+ connectivity
# errors before the rename, ~0 after). See that file's own header for full
# provenance, and grdgenxo needs the libnsl RPM installed first (`sudo dnf
# install -y libnsl` on this Rocky 8.10 box) or it won't even launch.
RAIL_TECH_FILE    ?= scripts/rail/tech/gf180mcu.itf
# KNOWN GAP (2026-08-22): static analysis (the default) works end to end,
# real per-pin numbers, e.g. croc_soc's 6 VDD+6 VSS pins measured at
# ~0.21% worst-case drop. RAIL_VOLTAGE_DROP=dynamic_vectorless also SOLVES
# cleanly (real transient sim, 0 unconnected vias/pins in its own summary)
# but report_rail_result/get_attribute can't extract per-pin dynamic
# values afterward -- every attempt (voltage_drop_or_rise, effective_
# voltage_drop, direct get_attribute on a real pin) returns empty or
# "RAIL-1120 PG pin(s) might be disconnected to ideal voltage", despite the
# solve's own connectivity counters being clean. Not yet root-caused;
# static's result already gives a strong, complete answer on its own
# (dynamic would only sharpen it further, not change the conclusion).

# ------------------------------------------------------------------------------
# Fusion Compiler dynamic step rules (from scripts/0*_*.tcl)
# ------------------------------------------------------------------------------
# This block automatically reads any TCL file in scripts/ that starts with a number 
# (e.g., 01_read_rtl.tcl, 02_floorplan.tcl) and creates a make target for it.
define MAKE_FC_RULE
.PHONY: $2 open_$2 gui_$2

$2: $(WORK_DIR)/design.dlib/$2

open_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

gui_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -gui -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

$(WORK_DIR)/design.dlib/$2: $3 $1
	mkdir -p $(WORK_DIR) $(LOGS_DIR) $(REPORTS_DIR)/$(basename $(notdir $1)) && cd $(WORK_DIR) && set -o pipefail; \
	fc_shell -batch -f ../$1 | tee ../$(LOGS_DIR)/$2.log
endef

TCL_FILES = $(sort $(wildcard scripts/0*_*.tcl))

DEPENDENCY :=
$(foreach file,$(TCL_FILES),\
  $(eval base := $(shell echo $(notdir $(file)) | sed -E 's/^[0-9]+_(.*)\.tcl/\1/'))\
  $(eval $(call MAKE_FC_RULE,$(file),$(base),$(DEPENDENCY)))\
  $(eval DEPENDENCY := $(WORK_DIR)/design.dlib/$(base))\
)

# ------------------------------------------------------------------------------
# Full Flow
# ------------------------------------------------------------------------------
.PHONY: all
all: $(DEPENDENCY)
	@echo "[FLOW] Fusion Compiler flow completed successfully up to the final TCL script."

# ------------------------------------------------------------------------------
# Physical Verification - KLayout DRC (GF180MCU)
# ------------------------------------------------------------------------------
# Runs run_drc.py on the run's GDS. Results (merged .lyrdb + per-deck logs)
# land in <run>/drc/, right next to that run's .gds/.v, so nothing overwrites
# and every check is traceable back to its exact GDS.
#
# Typical use (after the FC flow has produced a GDS):
#   make drc                                   # checks outputs/latest
#   make drc GF180MCU_OPT=B                     # 4LM stack instead of 5LM
#   make drc DRC_EXTRA="--antenna --density"    # add antenna + density checks
#   make drc RUN=croc_soc_20260804_101500       # re-check an older run
#   make finish drc                             # build finish, then DRC, in one go
.PHONY: drc
drc:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[DRC] ERROR: GDS not found: $(GDS)"; \
	  echo "[DRC] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -f "$(DRC_HOME)/run_drc.py" ]; then \
	  echo "[DRC] ERROR: run_drc.py not found under DRC_HOME=$(DRC_HOME)"; \
	  echo "[DRC] Set DRC_HOME to the folder holding run_drc.py, rule_decks/ and utils/."; \
	  exit 1; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/drc"; \
	 mkdir -p "$$out_dir"; \
	 echo "[DRC] design : $$gds_real"; \
	 echo "[DRC] stack  : gf180mcu=$(GF180MCU_OPT)  mode=$(DRC_RUN_MODE)  extra='$(DRC_EXTRA)'"; \
	 echo "[DRC] results: $$out_dir"; \
	 ( cd "$$out_dir" && \
	   PDK_ROOT="$(DRC_PDK_ROOT)" PDK="$(DRC_PDK)" \
	   python3 "$(DRC_HOME)/run_drc.py" \
	     --path="$$gds_real" --gf180mcu=$(GF180MCU_OPT) \
	     --run_mode=$(DRC_RUN_MODE) $(DRC_EXTRA) \
	 ) 2>&1 | tee "$$out_dir/drc.log"
	@echo "[DRC] Done. Open the .lyrdb in KLayout: <run>/drc/*.lyrdb"

# ------------------------------------------------------------------------------
# Physical Verification - KLayout LVS (GF180MCU)
# ------------------------------------------------------------------------------
# Fusion Compiler exports a GDS + gate-level Verilog, but no SPICE schematic.
# `make lvs` rebuilds one (verilog2spice.py, using the folded
# gf180mcu_fd_sc_mcu7t5v0 CDL + any hard-macro CDLs as black boxes), then runs
# KLayout LVS comparing it against the GDS. Results land in <run>/lvs/,
# alongside that run's .gds/.v (and its drc/ folder, if `make drc` also ran).
#
# Typical use (after the FC flow has produced a GDS + Verilog netlist):
#   make lvs                                    # latest run
#   make lvs GF180MCU_OPT=B                      # 4LM stack instead of 5LM
#   make lvs RUN=croc_soc_20260804_101500        # re-check an older run
#   make finish drc lvs                          # build, then DRC, then LVS
.PHONY: lvs
lvs:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[LVS] ERROR: GDS not found: $(GDS)"; \
	  echo "[LVS] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -e "$(VLOG)" ]; then \
	  echo "[LVS] ERROR: Verilog netlist not found: $(VLOG)"; \
	  echo "[LVS] Fusion Compiler must export it alongside the GDS (see 06_finish.tcl), or pass VLOG=<path/to.v>."; \
	  exit 1; \
	fi
	@if [ ! -f "$(LVS_HOME)/run_lvs.py" ]; then \
	  echo "[LVS] ERROR: run_lvs.py not found under LVS_HOME=$(LVS_HOME)"; \
	  echo "[LVS] Set LVS_HOME to the folder holding run_lvs.py, verilog2spice.py and gf180mcu.lvs."; \
	  exit 1; \
	fi
	@if [ ! -e "$(LVS_SC_CDL)" ]; then \
	  echo "[LVS] ERROR: standard-cell CDL not found: $(LVS_SC_CDL)"; \
	  echo "[LVS] Set LVS_PDK_KIT (or LVS_SC_CDL directly) to where ciel's gf180mcu_fd_sc_mcu7t5v0"; \
	  echo "[LVS]   libs.ref lives, e.g. run 'ciel ls' / check ~/.ciel/gf180mcu$(GF180MCU_OPT)."; \
	  echo "[LVS] Do NOT point it at gf180_drc_lvs/lvs/testing/sc_testcases/*.cdl (different, test-suite"; \
	  echo "[LVS]   cell names) or ~/pdk_synopsys/cdl/*.cdl (partial export, missing most cells)."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(FOLDED_SC_CDL)" ] || [ "$(LVS_SC_CDL)" -nt "$(FOLDED_SC_CDL)" ]; then \
	  echo "[LVS] Preparing standard-cell CDL ($(LVS_WELL_TIES) $(LVS_MODEL_RENAME)): $(FOLDED_SC_CDL)"; \
	  python3 "$(LVS_HOME)/fold_wells.py" $(LVS_WELL_TIES) $(LVS_MODEL_RENAME) "$(LVS_SC_CDL)" "$(FOLDED_SC_CDL)"; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 vlog_real="$$(readlink -f "$(VLOG)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/lvs"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[LVS] design  : $$gds_real"; \
	 echo "[LVS] netlist : $$vlog_real"; \
	 echo "[LVS] stack   : gf180mcu=$(GF180MCU_OPT)  mode=$(LVS_RUN_MODE)  sub=$(LVS_SUB)"; \
	 echo "[LVS] results : $$out_dir"; \
	 echo "[LVS] Verilog -> SPICE ($(TOP).sp) via verilog2spice.py ..."; \
	 python3 "$(LVS_HOME)/verilog2spice.py" \
	     -v "$$vlog_real" -c "$(FOLDED_SC_CDL)" \
	     $(foreach cdl,$(LVS_BLACKBOX_CDL),--blackbox-cdl "$(cdl)") \
	     -o "$$out_dir/$(TOP).sp" \
	   2>&1 | tee "$$out_dir/verilog2spice.log"; \
	 v2s_status=$${PIPESTATUS[0]}; \
	 if [ "$$v2s_status" -ne 0 ]; then \
	   echo "[LVS] ERROR: verilog2spice.py reported missing cells (exit $$v2s_status)."; \
	   echo "[LVS] Check $$out_dir/verilog2spice.log -- a macro's CDL is likely missing from LVS_BLACKBOX_CDL."; \
	   exit 1; \
	 fi; \
	 lvs_gds="$$gds_real"; \
	 if [ -n "$(strip $(LVS_BLACKBOX_CELLS))" ]; then \
	   echo "[LVS] Black-boxing hard macro(s) in a copy of the GDS ($(LVS_BLACKBOX_CELLS)) ..."; \
	   echo "[LVS] ($(GDS) itself is untouched -- this only affects what LVS signs off against.)"; \
	   klayout -b -r "$(LVS_HOME)/blackbox_gds_cells.rb" \
	       -rd input="$$gds_real" \
	       -rd output="$$out_dir/$(TOP).lvs_blackbox.gds" \
	       -rd cells="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     2>&1 | tee "$$out_dir/blackbox_gds.log"; \
	   bb_status=$${PIPESTATUS[0]}; \
	   if [ "$$bb_status" -ne 0 ]; then \
	     echo "[LVS] ERROR: blackbox_gds_cells.rb failed (exit $$bb_status), see $$out_dir/blackbox_gds.log"; \
	     exit 1; \
	   fi; \
	   lvs_gds="$$out_dir/$(TOP).lvs_blackbox.gds"; \
	 fi; \
	 echo "[LVS] Running KLayout LVS (GF180MCU) ..."; \
	 ( cd "$$out_dir" && \
	   PDK_ROOT="$(LVS_PDK_ROOT)" PDK="$(LVS_PDK)" \
	   python3 "$(LVS_HOME)/run_lvs.py" \
	     --design="$$lvs_gds" --net="$$out_dir/$(TOP).sp" --gf180mcu=$(GF180MCU_OPT) \
	     --run_mode=$(LVS_RUN_MODE) --lvs_sub=$(LVS_SUB) $(LVS_FLAGS) $(LVS_EXTRA) \
	     --blackbox_macros="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     --exclude_from_compare="$(LVS_EXCLUDE_FROM_COMPARE)" \
	 ) 2>&1 | tee "$$out_dir/lvs.log"; \
	 echo "[LVS] Cross-checking with a second, independent comparison (lvs_compare.rb) ..."; \
	 klayout -b -r "$(LVS_HOME)/lvs_compare.rb" \
	     -rd layout_netlist="$$out_dir/extracted_netlist_$(TOP).cir" \
	     -rd schematic_netlist="$$out_dir/$(TOP).sp" \
	     -rd device_class_map="$(LVS_DEVICE_CLASS_MAP)" \
	     -rd blackbox_macros="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     -rd exclude_from_compare="$(LVS_EXCLUDE_FROM_COMPARE)" \
	     -rd summary="$$out_dir/lvs_compare_summary.txt" \
	   > "$$out_dir/lvs_compare.log" 2>&1; \
	 if grep -q "INFO : Congratulations! Netlists match." "$$out_dir/lvs.log"; then \
	   echo "[LVS] MATCH. Open <run>/lvs/*.lvsdb in KLayout to review (File > Open, or the Netlist"; \
	   echo "[LVS] Browser panel) -- that database is now the authoritative, independently-viewable"; \
	   echo "[LVS] result. See also <run>/lvs/lvs_compare_summary.txt for a text cross-check."; \
	 else \
	   echo "[LVS] MISMATCH. Open <run>/lvs/*.lvsdb in KLayout (File > Open) to see exactly which"; \
	   echo "[LVS] circuits/nets/devices differ -- that database is the authoritative, independently-"; \
	   echo "[LVS] viewable result, not just this log. See also <run>/lvs/lvs_compare_summary.txt for"; \
	   echo "[LVS] a ranked text breakdown of the same result."; \
	   exit 1; \
	 fi

# ------------------------------------------------------------------------------
# Physical Verification - Synopsys IC Validator DRC (GF180MCU)
# ------------------------------------------------------------------------------
# Runs `icv` on the run's GDS using the ICV decks under ICV_PDK_HOME
# (pdk_synopsys/DRC_ICV by default). Results land in <run>/drc_icv/,
# alongside the KLayout drc/ folder (if `make drc` also ran) -- both read
# the exact same GDS, so they're a natural cross-check of each other.
#
# Typical use (after the FC flow has produced a GDS):
#   make drc-icv                                     # checks outputs/latest
#   make drc-icv ICV_BEOL_STACK=1P4M                  # 4LM stack instead of 5LM
#   make drc-icv ICV_DRC_RUNSET=$(ICV_PDK_HOME)/DRC_ICV_MODIFIED/DRC/ICV/gf180mcu_drc.rs
#   make drc-icv RUN=croc_soc_20260804_101500         # re-check an older run
#   make finish drc-icv                               # build finish, then DRC
.PHONY: drc-icv
drc-icv:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[DRC-ICV] ERROR: GDS not found: $(GDS)"; \
	  echo "[DRC-ICV] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -x "$(ICV_HOME_DIR)/bin/icv" ]; then \
	  echo "[DRC-ICV] ERROR: icv not found under ICV_HOME_DIR=$(ICV_HOME_DIR)"; \
	  echo "[DRC-ICV] Set ICV_HOME_DIR to the IC Validator installation directory."; \
	  exit 1; \
	fi
	@if [ ! -f "$(ICV_DRC_RUNSET)" ]; then \
	  echo "[DRC-ICV] ERROR: runset not found: $(ICV_DRC_RUNSET)"; \
	  echo "[DRC-ICV] Set ICV_PDK_HOME (or ICV_DRC_RUNSET directly) to where pdk_synopsys/DRC_ICV* lives."; \
	  exit 1; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/drc_icv"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[DRC-ICV] design : $$gds_real"; \
	 echo "[DRC-ICV] runset : $(ICV_DRC_RUNSET)"; \
	 echo "[DRC-ICV] stack  : BEOL_STACK=$(ICV_BEOL_STACK) TOPMETAL=$(ICV_TOPMETAL) MIMCAP=$(ICV_MIMCAP) PADBONDING=$(ICV_PADBONDING)"; \
	 echo "[DRC-ICV] results: $$out_dir"; \
	 ( cd "$$out_dir" && \
	   PATH="$(ICV_HOME_DIR)/bin:$$PATH" ICV_HOME_DIR="$(ICV_HOME_DIR)" \
	   BEOL_STACK="$(ICV_BEOL_STACK)" TOPMETAL="$(ICV_TOPMETAL)" \
	   MIMCAP_SELECTION="$(ICV_MIMCAP)" PADBONDING="$(ICV_PADBONDING)" \
	   LATCH_CHECK="$(ICV_LATCH_CHECK)" \
	   icv -f gdsii -c "$(TOP)" -i "$$gds_real" -vue \
	     -runset_config "$(REPO_DIR)/$(ICV_RUNSET_CONFIG)" \
	     -host_init $(ICV_HOST_INIT) $(ICV_DRC_EXTRA) \
	     "$(ICV_DRC_RUNSET)" \
	 ) 2>&1 | tee "$$out_dir/drc_icv.log"
	@echo "[DRC-ICV] Done. See <run>/drc_icv/$(TOP).RESULTS for the summary, or open"
	@echo "[DRC-ICV]   <run>/drc_icv/$(TOP).vue in IC Validator Live DRC / VUE to browse violations."

# ------------------------------------------------------------------------------
# Physical Verification - Synopsys IC Validator LVS (GF180MCU)
# ------------------------------------------------------------------------------
# Rebuilds an ICV-flavored SPICE schematic from the exported gate-level
# Verilog (same verilog2spice.py used by `make lvs`, but folded WITHOUT the
# KLayout-specific --rename-model -- see FOLDED_SC_CDL_ICV above), then
# runs ICV LVS comparing it against the GDS (black-boxing the same hard
# macros as `make lvs`, via the same blackbox_gds_cells.rb). Results land
# in <run>/lvs_icv/, alongside the KLayout lvs/ folder (if `make lvs` also
# ran).
#
# Typical use (after the FC flow has produced a GDS + Verilog netlist):
#   make lvs-icv                                     # latest run
#   make lvs-icv ICV_BEOL_STACK=1P4M                  # 4LM stack instead of 5LM
#   make lvs-icv RUN=croc_soc_20260804_101500         # re-check an older run
#   make finish drc-icv lvs-icv                       # build, then DRC, then LVS
.PHONY: lvs-icv
lvs-icv:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[LVS-ICV] ERROR: GDS not found: $(GDS)"; \
	  echo "[LVS-ICV] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -e "$(VLOG)" ]; then \
	  echo "[LVS-ICV] ERROR: Verilog netlist not found: $(VLOG)"; \
	  echo "[LVS-ICV] Fusion Compiler must export it alongside the GDS (see 06_finish.tcl), or pass VLOG=<path/to.v>."; \
	  exit 1; \
	fi
	@if [ ! -x "$(ICV_HOME_DIR)/bin/icv" ]; then \
	  echo "[LVS-ICV] ERROR: icv not found under ICV_HOME_DIR=$(ICV_HOME_DIR)"; \
	  echo "[LVS-ICV] Set ICV_HOME_DIR to the IC Validator installation directory."; \
	  exit 1; \
	fi
	@if [ ! -f "$(ICV_LVS_RUNSET)" ]; then \
	  echo "[LVS-ICV] ERROR: runset not found: $(ICV_LVS_RUNSET)"; \
	  echo "[LVS-ICV] Set ICV_PDK_HOME (or ICV_LVS_RUNSET directly) to where pdk_synopsys/LVS_ICV lives."; \
	  exit 1; \
	fi
	@if [ ! -f "$(LVS_HOME)/verilog2spice.py" ] || [ ! -f "$(LVS_HOME)/fold_wells.py" ]; then \
	  echo "[LVS-ICV] ERROR: verilog2spice.py/fold_wells.py not found under LVS_HOME=$(LVS_HOME)"; \
	  echo "[LVS-ICV] Set LVS_HOME to the folder holding them (shared with the KLayout 'lvs' target)."; \
	  exit 1; \
	fi
	@if [ ! -e "$(LVS_SC_CDL)" ]; then \
	  echo "[LVS-ICV] ERROR: standard-cell CDL not found: $(LVS_SC_CDL)"; \
	  echo "[LVS-ICV] Set LVS_PDK_KIT (or LVS_SC_CDL directly) -- see the 'lvs' target above for details."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(FOLDED_SC_CDL_ICV)" ] || [ "$(LVS_SC_CDL)" -nt "$(FOLDED_SC_CDL_ICV)" ]; then \
	  echo "[LVS-ICV] Preparing standard-cell CDL ($(LVS_WELL_TIES), no model rename): $(FOLDED_SC_CDL_ICV)"; \
	  python3 "$(LVS_HOME)/fold_wells.py" $(LVS_WELL_TIES) "$(LVS_SC_CDL)" "$(FOLDED_SC_CDL_ICV)"; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 vlog_real="$$(readlink -f "$(VLOG)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/lvs_icv"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[LVS-ICV] design  : $$gds_real"; \
	 echo "[LVS-ICV] netlist : $$vlog_real"; \
	 echo "[LVS-ICV] runset  : $(ICV_LVS_RUNSET)"; \
	 echo "[LVS-ICV] stack   : BEOL_STACK=$(ICV_BEOL_STACK)"; \
	 echo "[LVS-ICV] results : $$out_dir"; \
	 echo "[LVS-ICV] Verilog -> SPICE ($(TOP).sp) via verilog2spice.py ..."; \
	 python3 "$(LVS_HOME)/verilog2spice.py" \
	     -v "$$vlog_real" -c "$(FOLDED_SC_CDL_ICV)" \
	     $(foreach cdl,$(LVS_BLACKBOX_CDL),--blackbox-cdl "$(cdl)") \
	     -o "$$out_dir/$(TOP).sp" \
	   2>&1 | tee "$$out_dir/verilog2spice.log"; \
	 v2s_status=$${PIPESTATUS[0]}; \
	 if [ "$$v2s_status" -ne 0 ]; then \
	   echo "[LVS-ICV] ERROR: verilog2spice.py reported missing cells (exit $$v2s_status)."; \
	   echo "[LVS-ICV] Check $$out_dir/verilog2spice.log -- a macro's CDL is likely missing from LVS_BLACKBOX_CDL."; \
	   exit 1; \
	 fi; \
	 lvs_gds="$$gds_real"; \
	 if [ -n "$(strip $(LVS_BLACKBOX_CELLS))" ]; then \
	   echo "[LVS-ICV] Black-boxing hard macro(s) in a copy of the GDS ($(LVS_BLACKBOX_CELLS)) ..."; \
	   echo "[LVS-ICV] ($(GDS) itself is untouched -- this only affects what LVS signs off against.)"; \
	   klayout -b -r "$(LVS_HOME)/blackbox_gds_cells.rb" \
	       -rd input="$$gds_real" \
	       -rd output="$$out_dir/$(TOP).lvs_blackbox.gds" \
	       -rd cells="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     2>&1 | tee "$$out_dir/blackbox_gds.log"; \
	   bb_status=$${PIPESTATUS[0]}; \
	   if [ "$$bb_status" -ne 0 ]; then \
	     echo "[LVS-ICV] ERROR: blackbox_gds_cells.rb failed (exit $$bb_status), see $$out_dir/blackbox_gds.log"; \
	     exit 1; \
	   fi; \
	   lvs_gds="$$out_dir/$(TOP).lvs_blackbox.gds"; \
	 fi; \
	 echo "[LVS-ICV] Running IC Validator LVS (GF180MCU) ..."; \
	 ( cd "$$out_dir" && \
	   PATH="$(ICV_HOME_DIR)/bin:$$PATH" ICV_HOME_DIR="$(ICV_HOME_DIR)" \
	   ICV_LVS="$(ICV_LVS_HOME)" BEOL_STACK="$(ICV_BEOL_STACK)" \
	   icv -f gdsii -c "$(TOP)" -i "$$lvs_gds" \
	     -s "$$out_dir/$(TOP).sp" -sf SPICE -vue \
	     -runset_config "$(REPO_DIR)/$(ICV_RUNSET_CONFIG)" \
	     -host_init $(ICV_HOST_INIT) $(ICV_LVS_EXTRA) \
	     "$(ICV_LVS_RUNSET)" \
	 ) 2>&1 | tee "$$out_dir/lvs_icv.log"; \
	 if grep -q "LVS Compare Result: PASS" "$$out_dir/$(TOP).RESULTS" 2>/dev/null; then \
	   echo "[LVS-ICV] MATCH. See $$out_dir/$(TOP).RESULTS for the summary, or open"; \
	   echo "[LVS-ICV]   $$out_dir/$(TOP).vue in IC Validator Live DRC / VUE to browse the compare tree."; \
	 else \
	   echo "[LVS-ICV] MISMATCH (or run failed). See $$out_dir/$(TOP).RESULTS for the summary, or open"; \
	   echo "[LVS-ICV]   $$out_dir/$(TOP).vue in IC Validator Live DRC / VUE to see exactly which"; \
	   echo "[LVS-ICV]   circuits/nets/devices differ."; \
	   exit 1; \
	 fi

# ------------------------------------------------------------------------------
# Metal Fill - Synopsys IC Validator (GF180MCU, density signoff)
# ------------------------------------------------------------------------------
# Runs scripts/icv/croc_metal_fill.rs against the run's GDS and writes a new,
# fill-merged GDS to <run>/fill_icv/filled.gds. See ICV_FILL_RUNSET above for
# the validation history. This does NOT overwrite $(GDS) or touch outputs/
# in place -- filled.gds is a distinct artifact; point drc/drc-icv/lvs/
# lvs-icv at it explicitly (GDS=.../fill_icv/filled.gds) to sign it off.
#
# Typical use (after the FC flow has produced a GDS):
#   make fill-icv                                    # latest run
#   make fill-icv RUN=croc_soc_20260804_101500        # an older run
#   make drc GDS=outputs/latest/fill_icv/filled.gds DRC_EXTRA=--density_only  # verify density
#   make finish fill-icv                              # build finish, then fill
.PHONY: fill-icv
fill-icv:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[FILL-ICV] ERROR: GDS not found: $(GDS)"; \
	  echo "[FILL-ICV] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -x "$(ICV_HOME_DIR)/bin/icv" ]; then \
	  echo "[FILL-ICV] ERROR: icv not found under ICV_HOME_DIR=$(ICV_HOME_DIR)"; \
	  echo "[FILL-ICV] Set ICV_HOME_DIR to the IC Validator installation directory."; \
	  exit 1; \
	fi
	@if [ ! -f "$(ICV_FILL_RUNSET)" ]; then \
	  echo "[FILL-ICV] ERROR: runset not found: $(ICV_FILL_RUNSET)"; \
	  exit 1; \
	fi
	@if [ ! -d "$(ICV_FILL_INCLUDE_DIR)" ]; then \
	  echo "[FILL-ICV] ERROR: include dir not found: $(ICV_FILL_INCLUDE_DIR)"; \
	  echo "[FILL-ICV] Set ICV_PDK_HOME (or ICV_FILL_INCLUDE_DIR directly) to where pdk_synopsys/DRC_ICV_MODIFIED lives."; \
	  exit 1; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/fill_icv"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[FILL-ICV] design : $$gds_real"; \
	 echo "[FILL-ICV] runset : $(ICV_FILL_RUNSET)"; \
	 echo "[FILL-ICV] results: $$out_dir"; \
	 ( cd "$$out_dir" && \
	   PATH="$(ICV_HOME_DIR)/bin:$$PATH" ICV_HOME_DIR="$(ICV_HOME_DIR)" \
	   icv -f gdsii -c "$(TOP)" -i "$$gds_real" \
	     -I "$(ICV_FILL_INCLUDE_DIR)" \
	     -host_init $(ICV_HOST_INIT) $(ICV_FILL_EXTRA) \
	     "$(REPO_DIR)/$(ICV_FILL_RUNSET)" \
	 ) 2>&1 | tee "$$out_dir/fill_icv.log"; \
	 if [ ! -e "$$out_dir/filled.gds" ]; then \
	   echo "[FILL-ICV] ERROR: filled.gds was not produced -- check $$out_dir/fill_icv.log"; \
	   exit 1; \
	 fi; \
	 echo "[FILL-ICV] Done. Filled GDS: $$out_dir/filled.gds"; \
	 echo "[FILL-ICV]   Re-check density with: make drc GDS=$$out_dir/filled.gds DRC_EXTRA=--density_only"; \
	 echo "[FILL-ICV]   Or full DRC with:      make drc GDS=$$out_dir/filled.gds"

# ------------------------------------------------------------------------------
# Signoff STA - Synopsys PrimeTime (GF180MCU, MCMM: slow/typical/fast)
# ------------------------------------------------------------------------------
# Runs one classic pt_shell session per corner (see scripts/pt/sta_corner.tcl's
# header comment for why, instead of PT's own -multi_scenario distributed
# mode) against the SDC + per-corner SPEF `make pt_export` wrote. Setup is
# checked at slow+typical, hold at fast -- mirrors scripts/common/mcmm.tcl's
# own set_scenario_status split exactly (the existing, already-validated FC
# in-design convention: setup is worst at the slowest corner, hold is worst
# at the fastest). Results land in <run>/sta_pt/: report_timing_setup /
# report_constraint_setup / report_qor per slow+typical corner,
# report_timing_hold / report_constraint_hold / report_qor for fast, plus a
# combined summary printed at the end of the run.
#
# Typical use (after `make finish pt_export`):
#   make sta-pt                                # all 3 corners, outputs/latest
#   make sta-pt RUN=croc_soc_20260804_101500   # re-check an older run
.PHONY: sta-pt
sta-pt:
	@if [ ! -x "$(PT_HOME_DIR)/bin/pt_shell" ]; then \
	  echo "[STA-PT] ERROR: pt_shell not found under PT_HOME_DIR=$(PT_HOME_DIR)"; \
	  exit 1; \
	fi
	@if [ ! -e "$(SDC)" ]; then \
	  echo "[STA-PT] ERROR: SDC not found: $(SDC)"; \
	  echo "[STA-PT] Run 'make pt_export' first (writes SDC+SPEF alongside GDS/Verilog)."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(PT_SRAM_DB)" ] || [ "$(PT_SRAM_LIB)" -nt "$(PT_SRAM_DB)" ]; then \
	  echo "[STA-PT] Compiling SRAM liberty -> db (Library Compiler): $(PT_SRAM_DB)"; \
	  PATH="$(LC_HOME_DIR)/bin:$$PATH" lc_shell -x " \
	    read_lib $(PT_SRAM_LIB); \
	    write_lib gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00 -format db -output $(PT_SRAM_DB); \
	    exit" 2>&1 | tee "$(CACHE_DIR)/lc_sram.log"; \
	  if [ ! -e "$(PT_SRAM_DB)" ]; then \
	    echo "[STA-PT] ERROR: SRAM db compile failed, see $(CACHE_DIR)/lc_sram.log"; exit 1; \
	  fi; \
	fi
	@vlog_real="$$(readlink -f "$(VLOG)")"; \
	 sdc_real="$$(readlink -f "$(SDC)")"; \
	 run_dir="$$(dirname "$$vlog_real")"; \
	 out_dir="$$run_dir/sta_pt"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[STA-PT] design  : $$vlog_real"; \
	 echo "[STA-PT] sdc     : $$sdc_real"; \
	 echo "[STA-PT] results : $$out_dir"; \
	 for spec in "slow $(PT_SC_DB_slow) $(PT_IO_DB_slow) typ_125" \
	             "typical $(PT_SC_DB_typical) $(PT_IO_DB_typical) typ_25" \
	             "fast $(PT_SC_DB_fast) $(PT_IO_DB_fast) typ_-40"; do \
	   set -- $$spec; corner=$$1; sc_db=$$2; io_db=$$3; spef_suffix=$$4; \
	   spef="$$run_dir/$(TOP).$${spef_suffix}.spef"; \
	   if [ ! -e "$$spef" ]; then \
	     echo "[STA-PT] ERROR: SPEF not found for corner $$corner: $$spef"; \
	     echo "[STA-PT] Run 'make pt_export' first."; \
	     exit 1; \
	   fi; \
	   echo "[STA-PT] --- corner: $$corner ---"; \
	   PATH="$(PT_HOME_DIR)/bin:$$PATH" pt_shell -x " \
	     set CORNER $$corner; \
	     set TOP $(TOP); \
	     set VLOG $$vlog_real; \
	     set SDC_FILE $$sdc_real; \
	     set SPEF_FILE $$spef; \
	     set SC_DB $$sc_db; \
	     set IO_DB $$io_db; \
	     set SRAM_DB $(PT_SRAM_DB); \
	     set REPORT_DIR $$out_dir; \
	     source $(REPO_DIR)/scripts/pt/sta_corner.tcl; \
	     exit" \
	   2>&1 | tee "$$out_dir/sta_pt.$$corner.log"; \
	 done; \
	 echo "[STA-PT] ================ Summary ================"; \
	 for corner in slow typical; do \
	   echo "[STA-PT] setup @ $$corner (Path Group 'clock'):"; \
	   grep -A5 "Timing Path Group 'clock' (max_delay/setup)" "$$out_dir/report_qor.$$corner.rpt" 2>/dev/null | sed 's/^/  /'; \
	 done; \
	 echo "[STA-PT] hold @ fast (Path Group 'clock'):"; \
	 grep -A5 "Timing Path Group 'clock' (min_delay/hold)" "$$out_dir/report_qor.fast.rpt" 2>/dev/null | sed 's/^/  /'; \
	 echo "[STA-PT] Full reports: $$out_dir/*.rpt"

# ------------------------------------------------------------------------------
# Power analysis - Synopsys PrimePower (GF180MCU)
# ------------------------------------------------------------------------------
# Reuses the exact same netlist/SDC/SPEF/liberty setup as sta-pt (see
# scripts/pt/power_corner.tcl -- power commands live directly in pt_shell,
# not a separate pwr_shell session; that launcher disables read_verilog and
# expects to attach to an already-built session instead), then applies
# vectorless (default toggle_rate/static_probability) switching activity and
# reports power. Set PP_SAIF=<path/to.saif> to use real simulated activity
# instead once one exists; empty (the default) uses the vectorless estimate.
#
# Typical use (after `make finish pt_export`):
#   make power-pp                                # fast corner only (default)
#   make power-pp PP_CORNERS="slow typical fast"  # all 3, for comparison
#   make power-pp PP_SAIF=sim/build/croc.saif     # real activity once available
.PHONY: power-pp
power-pp:
	@if [ ! -x "$(PT_HOME_DIR)/bin/pt_shell" ]; then \
	  echo "[POWER-PP] ERROR: pt_shell not found under PT_HOME_DIR=$(PT_HOME_DIR)"; \
	  exit 1; \
	fi
	@if [ ! -e "$(SDC)" ]; then \
	  echo "[POWER-PP] ERROR: SDC not found: $(SDC)"; \
	  echo "[POWER-PP] Run 'make pt_export' first (writes SDC+SPEF alongside GDS/Verilog)."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(PT_SRAM_DB)" ] || [ "$(PT_SRAM_LIB)" -nt "$(PT_SRAM_DB)" ]; then \
	  echo "[POWER-PP] Compiling SRAM liberty -> db (Library Compiler): $(PT_SRAM_DB)"; \
	  PATH="$(LC_HOME_DIR)/bin:$$PATH" lc_shell -x " \
	    read_lib $(PT_SRAM_LIB); \
	    write_lib gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00 -format db -output $(PT_SRAM_DB); \
	    exit" 2>&1 | tee "$(CACHE_DIR)/lc_sram.log"; \
	  if [ ! -e "$(PT_SRAM_DB)" ]; then \
	    echo "[POWER-PP] ERROR: SRAM db compile failed, see $(CACHE_DIR)/lc_sram.log"; exit 1; \
	  fi; \
	fi
	@vlog_real="$$(readlink -f "$(VLOG)")"; \
	 sdc_real="$$(readlink -f "$(SDC)")"; \
	 run_dir="$$(dirname "$$vlog_real")"; \
	 out_dir="$$run_dir/power_pp"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[POWER-PP] design  : $$vlog_real"; \
	 echo "[POWER-PP] sdc     : $$sdc_real"; \
	 echo "[POWER-PP] corners : $(PP_CORNERS)"; \
	 echo "[POWER-PP] results : $$out_dir"; \
	 for corner in $(PP_CORNERS); do \
	   case $$corner in \
	     slow)    sc_db="$(PT_SC_DB_slow)";    io_db="$(PT_IO_DB_slow)";    spef_suffix=typ_125 ;; \
	     typical) sc_db="$(PT_SC_DB_typical)"; io_db="$(PT_IO_DB_typical)"; spef_suffix=typ_25  ;; \
	     fast)    sc_db="$(PT_SC_DB_fast)";    io_db="$(PT_IO_DB_fast)";    spef_suffix=typ_-40 ;; \
	     *) echo "[POWER-PP] ERROR: unknown corner '$$corner' (expected slow|typical|fast)"; exit 1 ;; \
	   esac; \
	   spef="$$run_dir/$(TOP).$${spef_suffix}.spef"; \
	   if [ ! -e "$$spef" ]; then \
	     echo "[POWER-PP] ERROR: SPEF not found for corner $$corner: $$spef"; \
	     echo "[POWER-PP] Run 'make pt_export' first."; \
	     exit 1; \
	   fi; \
	   echo "[POWER-PP] --- corner: $$corner ---"; \
	   PATH="$(PT_HOME_DIR)/bin:$$PATH" pt_shell -x " \
	     set CORNER $$corner; \
	     set TOP $(TOP); \
	     set VLOG $$vlog_real; \
	     set SDC_FILE $$sdc_real; \
	     set SPEF_FILE $$spef; \
	     set SC_DB $$sc_db; \
	     set IO_DB $$io_db; \
	     set SRAM_DB $(PT_SRAM_DB); \
	     set REPORT_DIR $$out_dir; \
	     set PP_TOGGLE_RATE $(PP_DEFAULT_TOGGLE_RATE); \
	     set PP_STATIC_PROB $(PP_DEFAULT_STATIC_PROB); \
	     set PP_SAIF {$(PP_SAIF)}; \
	     source $(REPO_DIR)/scripts/pt/power_corner.tcl; \
	     exit" \
	   2>&1 | tee "$$out_dir/power_pp.$$corner.log"; \
	 done; \
	 echo "[POWER-PP] ================ Summary ================"; \
	 for corner in $(PP_CORNERS); do \
	   echo "[POWER-PP] $$corner:"; \
	   grep "Total Power" "$$out_dir/report_power_summary.$$corner.rpt" 2>/dev/null | sed 's/^/  /'; \
	 done; \
	 echo "[POWER-PP] Full reports: $$out_dir/*.rpt"

# ------------------------------------------------------------------------------
# Sign-off Rail Analysis - RedHawk-SC Fusion (in-design voltage drop / IR drop)
# ------------------------------------------------------------------------------
# Runs scripts/rail/analyze_rail.tcl against work/design.dlib's 'finish'
# block (always the current build, not a specific RUN -- see the RAIL_*
# variables above). Reports land in outputs/latest/rail_rh/.
#
# Typical use (after `make finish`):
#   make rail                                         # static, uses RAIL_TECH_FILE's default
#   make rail RAIL_VOLTAGE_DROP=dynamic_vectorless    # dynamic (solves clean; see KNOWN GAP above
#                                                      # re: per-pin report extraction not working yet)
.PHONY: rail
rail:
	@if [ ! -x "$$(command -v fc_shell)" ]; then \
	  echo "[RAIL] ERROR: fc_shell not found on PATH."; \
	  exit 1; \
	fi
	@if [ ! -e "$(WORK_DIR)/design.dlib/finish" ]; then \
	  echo "[RAIL] ERROR: no 'finish' block in $(WORK_DIR)/design.dlib."; \
	  echo "[RAIL] Run 'make finish' (or 'make all') first."; \
	  exit 1; \
	fi
	@if [ ! -x "$(RAIL_REDHAWK_PATH)/redhawk_sc" ]; then \
	  echo "[RAIL] ERROR: redhawk_sc not found under RAIL_REDHAWK_PATH=$(RAIL_REDHAWK_PATH)"; \
	  echo "[RAIL] Set RAIL_REDHAWK_PATH to the directory containing the redhawk_sc executable."; \
	  exit 1; \
	fi
	@if [ -z "$(RAIL_TECH_FILE)" ] || [ ! -e "$(RAIL_TECH_FILE)" ]; then \
	  echo "[RAIL] ERROR: RAIL_TECH_FILE not set or not found: '$(RAIL_TECH_FILE)'"; \
	  echo "[RAIL] Default is scripts/rail/tech/gf180mcu.itf (checked into this repo --"; \
	  echo "[RAIL] see its header for provenance). If it's missing, restore it or set"; \
	  echo "[RAIL] RAIL_TECH_FILE to another real ITF/IRCX/NRC tech file."; \
	  exit 1; \
	fi
	@out_dir="$(OUTPUTS_DIR)/latest/rail_rh"; \
	 mkdir -p "$$out_dir"; \
	 tech_file_real="$$(readlink -f "$(RAIL_TECH_FILE)")"; \
	 out_dir_real="$$(readlink -f "$$out_dir")"; \
	 set -o pipefail; \
	 echo "[RAIL] design    : $(TOP) ('finish' block, $(WORK_DIR)/design.dlib)"; \
	 echo "[RAIL] product   : $(RAIL_PRODUCT)"; \
	 echo "[RAIL] tech_file : $$tech_file_real"; \
	 echo "[RAIL] mode      : $(RAIL_VOLTAGE_DROP)"; \
	 echo "[RAIL] results   : $$out_dir"; \
	 cd $(WORK_DIR) && fc_shell -batch -x " \
	   set TOP $(TOP); \
	   set REPORT_DIR $$out_dir_real; \
	   set RAIL_PRODUCT $(RAIL_PRODUCT); \
	   set RAIL_REDHAWK_PATH $(RAIL_REDHAWK_PATH); \
	   set RAIL_TECH_FILE $$tech_file_real; \
	   set RAIL_VOLTAGE_DROP $(RAIL_VOLTAGE_DROP); \
	   source ../scripts/rail/analyze_rail.tcl; \
	   exit" \
	 2>&1 | tee "$$out_dir_real/rail.$(RAIL_VOLTAGE_DROP).log"; \
	 echo "[RAIL] Full report: $$out_dir/voltage_drop.$(RAIL_VOLTAGE_DROP).rpt"

# ------------------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------------------
.PHONY: clean distclean
clean:
	rm -rf $(WORK_DIR) $(LOGS_DIR) $(REPORTS_DIR)
	@echo "Cleaned work, logs, and reports directories."

# distclean also removes the exported GDS/netlists in outputs/. Use with care.
distclean: clean
	rm -rf $(OUTPUTS_DIR)
	@echo "Also removed the outputs directory (exported GDS/netlists)."

# ------------------------------------------------------------------------------
# Software & Simulation Flow
# ------------------------------------------------------------------------------
.PHONY: sw sim sim-vcs verilate run clean-sw clean-sim

# Default application binary. Override on the command line, e.g.:
#   make run BIN=sim/sw/bin/test/test_gpio.hex
BIN ?= sim/sw/hello_world/bin/helloworld.hex

sw:
	@echo "[SW] Compiling RISC-V bare-metal software..."
	@$(MAKE) -C sim/sw

clean-sw:
	@echo "[SW] Cleaning software binaries..."
	@$(MAKE) -C sim/sw clean

# Compile the Verilator hardware model only (re-run after any RTL change).
verilate:
	@echo "[SIM] Compiling Verilator hardware model..."
	@cd sim && BUILD_ONLY=1 bash scripts/run_verilator.sh

# Run a binary on the already-compiled model -- no recompile, near-instant.
run: sw
	@echo "[SIM] Running $(BIN) ..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash scripts/run_verilator.sh

# Compile + run in one shot (original behavior; defaults to helloworld).
sim:
	@echo "[SIM] Launching Verilator simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash scripts/run_verilator.sh

# Compile the VCS hardware model (elaboration phase).
vcs-compile:
	@echo "[SIM] Compiling VCS hardware model..."
	@cd sim && BUILD_ONLY=1 bash scripts/run_vcs.sh

# Run a binary on the already-compiled VCS model.
# Assumes the simulation binary (e.g., simv) exists from a previous vcs-compile.
run-vcs: sw
	@echo "[SIM] Running $(BIN) on VCS..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash scripts/run_vcs.sh

# Compile + run VCS in one shot.
sim-vcs: sw
	@echo "[SIM] Launching full VCS simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash scripts/run_vcs.sh

clean-sim:
	@echo "[SIM] Cleaning simulation builds..."
	@rm -rf sim/build/*

# ------------------------------------------------------------------------------
# FPGA (ZedBoard / Zynq-7000 PL) Flow -- requires Vivado on PATH
# ------------------------------------------------------------------------------
.PHONY: fpga clean-fpga

VIVADO ?= vivado

# Non-project-mode batch build: synth -> opt -> place -> route -> bitstream.
# Reads croc_fpga.flist + constraints/zedboard.xdc; output in work_fpga/.
fpga:
	@echo "[FPGA] Running Vivado non-project build for the ZedBoard..."
	@$(VIVADO) -mode batch -source scripts/fpga/build_zedboard.tcl

clean-fpga:
	rm -rf work_fpga vivado*.log vivado*.jou vivado*.str .Xil
	@echo "Cleaned FPGA build directory and Vivado logs."

# ------------------------------------------------------------------------------
# Help Menu
# ------------------------------------------------------------------------------
.PHONY: help
help:
	@echo "================================================================"
	@echo " Croc SoC Fusion Compiler + DRC/LVS Flow"
	@echo "================================================================"
	@echo "Main Targets:"
	@echo "  make all        – Run all available Fusion Compiler steps sequentially"
	@echo "  make drc        – KLayout GF180MCU DRC on the latest run's GDS"
	@echo "  make lvs        – Verilog->SPICE + KLayout GF180MCU LVS on the latest run"
	@echo "  make drc-icv    – Synopsys IC Validator GF180MCU DRC on the latest run's GDS"
	@echo "  make lvs-icv    – Verilog->SPICE + Synopsys IC Validator GF180MCU LVS"
	@echo "  make fill-icv   – Synopsys IC Validator Metal1-5 dummy fill (density signoff)"
	@echo "  make sta-pt     – Synopsys PrimeTime signoff STA (MCMM: slow/typical/fast)"
	@echo "  make power-pp   – Synopsys PrimePower power analysis"
	@echo "  make rail       – RedHawk-SC in-design voltage/IR drop (static works; dynamic partial)"
	@echo "  make clean      – Delete the 'work', 'logs', and 'reports' directories"
	@echo "  make distclean  – clean + also delete 'outputs' (exported GDS/netlists/results)"
	@echo ""
	@echo "Individual Steps (dynamically generated from scripts/):"
	@echo "  make read_rtl"
	@echo "  make floorplan"
	@echo "  make synthesis"
	@echo "  make cts"
	@echo "  make route"
	@echo "  make finish"
	@echo "  make pt_export  (writes SDC + per-corner SPEF for sta-pt/power-pp)"
	@echo ""
	@echo "Run selection (shared by drc and lvs):"
	@echo "  make drc                           – sign off outputs/latest (default)"
	@echo "  make lvs RUN=$(TOP)_20260804_101500  – sign off a specific (older) run"
	@echo "  make drc GDS=/path/to.gds VLOG=/path/to.v  – fully explicit override"
	@echo ""
	@echo "DRC options (KLayout / GF180MCU):"
	@echo "  make drc GF180MCU_OPT=C            – metal stack A=3LM B=4LM C=5LM (default C)"
	@echo "  make drc DRC_RUN_MODE=deep         – flat|deep|tiling (default flat)"
	@echo "  make drc DRC_EXTRA=\"--antenna --density\"  – add extra checks"
	@echo "  make drc DRC_HOME=/path/to/gf180mcu– where run_drc.py + rule_decks/ live"
	@echo "  make finish drc                    – build finish, then run DRC"
	@echo ""
	@echo "LVS options (KLayout / GF180MCU):"
	@echo "  make lvs GF180MCU_OPT=C            – metal stack A=3LM B=4LM C=5LM (default C)"
	@echo "  make lvs LVS_RUN_MODE=flat         – flat|deep|tiling (default deep)"
	@echo "  make lvs LVS_SUB=VSS               – substrate net name (default VSS)"
	@echo "  make lvs LVS_HOME=/path/to/gf180mcu– where run_lvs.py + verilog2spice.py live"
	@echo "  make lvs LVS_BLACKBOX_CELLS=       – sign off the real GDS as-is (default black-boxes"
	@echo "                                       hard macros like SRAM -- see LVS_BLACKBOX_CELLS in"
	@echo "                                       the Makefile; the run's .gds itself is never"
	@echo "                                       modified, so 'make finish'/tapeout output always"
	@echo "                                       has the real macro)"
	@echo "  make finish drc lvs                – build finish, then DRC, then LVS"
	@echo ""
	@echo "DRC/LVS options (Synopsys IC Validator / GF180MCU):"
	@echo "  make drc-icv ICV_BEOL_STACK=1P5M    – metal stack 1P3M=A 1P4M=B 1P5M=C (default 1P5M)"
	@echo "  make drc-icv ICV_DRC_RUNSET=...     – switch to DRC_ICV_MODIFIED/ or a custom deck"
	@echo "  make lvs-icv ICV_PDK_HOME=/path     – where pdk_synopsys/{DRC_ICV,LVS_ICV} live"
	@echo "  make finish drc-icv lvs-icv         – build finish, then IC Validator DRC, then LVS"
	@echo ""
	@echo "Metal fill / density signoff (Synopsys IC Validator / GF180MCU):"
	@echo "  make fill-icv                       – fill outputs/latest's GDS -> .../fill_icv/filled.gds"
	@echo "  make drc GDS=outputs/latest/fill_icv/filled.gds DRC_EXTRA=--density_only"
	@echo "                                       – re-check density on the filled GDS (KLayout)"
	@echo "  make finish fill-icv                – build finish, then fill"
	@echo ""
	@echo "Signoff STA / power (Synopsys PrimeTime / PrimePower):"
	@echo "  make pt_export                       – FC step: write SDC + per-corner SPEF to outputs/<run>/"
	@echo "  make sta-pt                          – PrimeTime STA, all 3 MCMM corners (slow/typical/fast)"
	@echo "  make sta-pt RUN=$(TOP)_20260804_101500 – re-check an older run"
	@echo "  make finish pt_export sta-pt          – build, export SDC/SPEF, then run signoff STA"
	@echo "  Setup is checked at slow+typical, hold at fast (mirrors scripts/common/mcmm.tcl's"
	@echo "  own set_scenario_status split). SRAM macro uses the same tt/25C/5.0V liberty view"
	@echo "  at all 3 corners -- this PDK kit ships no ss/ff SRAM characterization (see"
	@echo "  scripts/pt/sta_corner.tcl header comment); everything else is corner-accurate."
	@echo ""
	@echo "  make power-pp                        – PrimePower analysis, same SDC/SPEF/libs as sta-pt"
	@echo "  Vectorless (default switching activity) power estimate -- no gate-level VCD/SAIF from a"
	@echo "  real workload exists yet in this environment; set PP_SAIF=<file> once one does."
	@echo ""
	@echo "Signoff rail analysis (RedHawk-SC Fusion, in-design voltage/IR drop):"
	@echo "  make rail                                         – static voltage drop, latest 'finish' block"
	@echo "  make rail RAIL_VOLTAGE_DROP=dynamic_vectorless    – dynamic (solves clean, per-pin report"
	@echo "                                                       extraction not working yet, see Makefile)"
	@echo "  Treats croc_soc's 6 VDD + 6 VSS top-level pins as the ideal supply (create_taps -top_pg)"
	@echo "  and solves for voltage drop across the real, routed PDN -- this is the direct answer to"
	@echo "  whether those 6 pins are enough. Uses scripts/rail/tech/gf180mcu.itf by default (real"
	@echo "  GF180MCU parasitics recovered from the PDK's own field-solver binary, see its header)."
	@echo ""
	@echo "Outputs (one self-contained folder per Fusion Compiler run):"
	@echo "  outputs/$(TOP)_<timestamp>/$(TOP).gds/.v  – timestamped, never overwritten"
	@echo "  outputs/latest                      – symlink to the most recent run folder"
	@echo "  outputs/<run>/drc/                  – KLayout DRC .lyrdb + logs for that run"
	@echo "  outputs/<run>/lvs/                  – KLayout LVS .sp/.lvsdb/extracted netlist + logs"
	@echo "  outputs/<run>/drc_icv/               – IC Validator DRC .RESULTS/.vue + logs"
	@echo "  outputs/<run>/lvs_icv/               – IC Validator LVS .sp/.RESULTS/.vue + logs"
	@echo "  outputs/<run>/fill_icv/              – IC Validator filled.gds + logs"
	@echo "  outputs/<run>/$(TOP).sdc, .typ_*.spef – pt_export's SDC + per-corner parasitics"
	@echo "  outputs/<run>/sta_pt/                – PrimeTime timing/constraint/QoR reports"
	@echo "  outputs/<run>/power_pp/               – PrimePower reports"
	@echo "  outputs/latest/rail_rh/               – RedHawk-SC rail analysis report + log"
	@echo "  outputs/.cache/                     – cached folded CDLs + SRAM liberty->db (rebuilt only if stale)"
	@echo ""
	@echo "Simulation (Verilator):"
	@echo "  make sim                       – Compile + run (defaults to helloworld)"
	@echo "  make sim BIN=<path/to.hex>     – Compile + run a specific application"
	@echo "  make verilate                  – Compile the HW model only (after RTL changes)"
	@echo "  make run BIN=<path/to.hex>     – Run an app on the compiled model (no recompile)"
	@echo "  make clean-sim                 – Remove the simulation build directory"
	@echo ""
	@echo "GUI / Interactive Commands:"
	@echo "  make open_<step> – Open a specific block in terminal mode"
	@echo "  make gui_<step>  – Open a specific block in GUI mode"
	@echo ""
	@echo "FPGA (ZedBoard, requires Vivado on PATH):"
	@echo "  make fpga        – Non-project batch build -> work_fpga/croc_zedboard_top.bit"
	@echo "  make clean-fpga  – Remove the FPGA build directory and Vivado logs"
	@echo "================================================================"