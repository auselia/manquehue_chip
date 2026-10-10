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

# Top-level power pins: {layer llx lly urx ury} in um, one list per net. They are the straight
# sections of the PG rings: Metal5 along the bottom and top, Metal4 down both sides. The first
# 30 um at each end is left out because the rings' own corner via arrays sit there.
# Each rectangle must lie on a shape of that net.
set PG_PINS {
  VDD {{Metal5 43 13 976.92 23} {Metal5 43 1767.48 976.92 1777.48} {Metal4 13 43 23 1747.48} {Metal4 996.92 43 1006.92 1747.48}}
  VSS {{Metal5 31 1 988.92 11} {Metal5 31 1779.48 988.92 1789.48} {Metal4 1 31 11 1759.48} {Metal4 1008.92 31 1018.92 1759.48}}
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