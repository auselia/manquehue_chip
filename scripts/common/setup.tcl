###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: ASIC Flow Environment Configuration Script
###############################################################################

# -----------------------------------------------------------------------------
# 1. Design & Project Variables
# -----------------------------------------------------------------------------
set TOP_MODULE          "croc_soc"
set DESIGN_NAME         $TOP_MODULE
set DESIGN_LIBRARY      "design.dlib"

set CLOCK_PORT_NAME     "clk_i" 
set CLOCK_PERIOD        50.0
# CLOCK_PERIOD is what the optimizer implements. The design is signed off at SPEC_PERIOD (AUS-9): the optimizer
# stops about 1.4 ns short of any period it is given, so a netlist implemented at 50 ns closes at 55 ns.
set SPEC_PERIOD         55.0

# Top-level power pins: {layer llx lly urx ury} in um, one list per net, for a block outline W x H.
# They are the straight sections of the PG rings (power_grid.tcl: VDD 13 to 23 um and VSS 1 to 11 um
# inside the outline): Metal5 along the bottom and top, Metal4 down both sides. The first 30 um at each
# end is left out because the rings' own corner via arrays sit there. The macro height follows the cell
# area (02_floorplan.tcl), so the pins are computed from the outline, not fixed numbers.
# 06_finish.tcl checks that each rectangle lies on a shape of its net.
proc pg_pins {W H} {
  return [list \
    VDD [list [list Metal5 43 13 [expr {$W - 43}] 23] \
              [list Metal5 43 [expr {$H - 23}] [expr {$W - 43}] [expr {$H - 13}]] \
              [list Metal4 13 43 23 [expr {$H - 43}]] \
              [list Metal4 [expr {$W - 23}] 43 [expr {$W - 13}] [expr {$H - 43}]]] \
    VSS [list [list Metal5 31 1 [expr {$W - 31}] 11] \
              [list Metal5 31 [expr {$H - 11}] [expr {$W - 31}] [expr {$H - 1}]] \
              [list Metal4 1 31 11 [expr {$H - 31}]] \
              [list Metal4 [expr {$W - 11}] 31 [expr {$W - 1}] [expr {$H - 31}]]]]
}
# Signoff-driven DRC ECO (drc_eco.tcl): the wafer.space KLayout deck, restricted to the routing
# rules FC cannot see, finds violations and the nets under them are rerouted.
set KLAYOUT_BIN         "/nix/store/dljmpck53kb6zxhvd73b688286b0kwkn-klayout-0.30.9/bin/klayout"
set DRC_DECK            "$::env(HOME)/.ciel/gf180mcuD/libs.tech/klayout/tech/drc/gf180mcu.drc"
set DRC_ECO_DECKS       "via,metal,contact"
set DRC_ECO_MAX_PASSES  3

# Metal4 and Metal5 stay open this far in from the boundary (um) so a parent grid can reach the pins.
set PG_PIN_BAND 25

# -----------------------------------------------------------------------------
# 2. PDK & Technology Paths
# -----------------------------------------------------------------------------
# Hardcoded path to Synopsys technology data for GF180MCU
set TECHLIB_DATA_DIR    "/home/navillegas/pdk_synopsys"

set STDCELL_TRACK_SIZE  7
set TECHNOLOGY          "gf180mcu"

# Tech Files & Layermaps
set PDK_DIR             $TECHLIB_DATA_DIR
# Official SRAM layouts (see 06_finish.tcl): ciel's gf180mcu_fd_ip_sram, override with SRAM_GDS_DIR
if { [info exists ::env(SRAM_GDS_DIR)] } { set SRAM_GDS_DIR $::env(SRAM_GDS_DIR) } else { set SRAM_GDS_DIR "$::env(HOME)/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram/gds" }
set TECH_FILE           "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_${STDCELL_TRACK_SIZE}t_mw.tf"
set ICC2GDS_LAYERMAP    "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_icc2gds.layermap"

set LPE_LAYERMAP        "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.layermap"
set LPE_NXTGRD          "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.nxtgrd"
set LPE_SPEC            "typ"

# -----------------------------------------------------------------------------
# 3. Reference Libraries (NDMs)
# -----------------------------------------------------------------------------
# Includes Standard Cells, IOs, and the SRAM Macro
set REFERENCE_LIBRARY [list \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_sc_mcu${STDCELL_TRACK_SIZE}t5v0.ndm" \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_io.ndm" \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_ip_sram__sram512x8m8wm1.ndm" \
]

# -----------------------------------------------------------------------------
# 4. Flow Constraints
# -----------------------------------------------------------------------------
# Exclude oversized cells and clock-related cells from synthesis datapath:
set SYN_IGNORE_CELLS    {*/*_12 */*_16 */*_20 */*__clk*}

# Define the set of cells eligible for Clock Tree Synthesis (CTS):
set CTS_CELLS           {*/*clk* */*icg* */*lat* */*dff*}