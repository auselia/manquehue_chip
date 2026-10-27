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

# Top-level power pins: {layer llx lly urx ury} in um per net, for an outline W x H. They are the straight parts of
# the PG rings (power_grid.tcl: VDD 13 to 23 um, VSS 1 to 11 um inside the outline), without the 30 um corner
# via arrays. Computed from the outline because the height follows the cell area. 06_finish.tcl checks each pin.
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
# Sign-off DRC ECOs (drc_eco.tcl): the wafer.space KLayout deck and its routing-rule decks.
set KLAYOUT_BIN         "/nix/store/dljmpck53kb6zxhvd73b688286b0kwkn-klayout-0.30.9/bin/klayout"
set DRC_DECK            "$::env(HOME)/.ciel/gf180mcuD/libs.tech/klayout/tech/drc/gf180mcu.drc"
set DRC_ECO_DECKS       "via,metal,contact"
set DRC_ECO_MAX_PASSES  4

# Metal4 and Metal5 stay open this far in from the boundary (um) so a parent grid can reach the pins.
set PG_PIN_BAND 25

# -----------------------------------------------------------------------------
# 2. PDK & Technology Paths
# -----------------------------------------------------------------------------
# Synopsys technology data for GF180MCU
set TECHLIB_DATA_DIR    "/home/navillegas/pdk_synopsys"

set STDCELL_TRACK_SIZE  7
set TECHNOLOGY          "gf180mcu"

# Tech Files & Layermaps
set PDK_DIR             $TECHLIB_DATA_DIR
# Official SRAM layouts (see 06_finish.tcl): ciel's gf180mcu_fd_ip_sram, override with SRAM_GDS_DIR
# Official IO cell layouts (chip GDS, chip/chip_export.tcl), override with IO_GDS_DIR
if { [info exists ::env(IO_GDS_DIR)] } { set IO_GDS_DIR $::env(IO_GDS_DIR) } else { set IO_GDS_DIR "$::env(HOME)/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_io/gds" }
if { [info exists ::env(SRAM_GDS_DIR)] } { set SRAM_GDS_DIR $::env(SRAM_GDS_DIR) } else { set SRAM_GDS_DIR "$::env(HOME)/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram/gds" }
set TECH_FILE           "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_${STDCELL_TRACK_SIZE}t_mw.tf"
set ICC2GDS_LAYERMAP    "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_icc2gds.layermap"

set LPE_LAYERMAP        "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.layermap"
set LPE_NXTGRD          "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.nxtgrd"
set LPE_SPEC            "typ"

# -----------------------------------------------------------------------------
# 3. Reference Libraries (NDMs)
# -----------------------------------------------------------------------------
# Standard cells, IO cells and the SRAM macro
set REFERENCE_LIBRARY [list \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_sc_mcu${STDCELL_TRACK_SIZE}t5v0.ndm" \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_io.ndm" \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_ip_sram__sram512x8m8wm1.ndm" \
]

# Chip floorplan (02_floorplan.tcl with CHIP_FLOORPLAN=1): the AC3E pad ring, the wafer.space IPs and the DC-DC
# wrappers around the croc logic. Their views are in work/chip_macros.ndm (make chip_macros_ndm, DCDC_GDS_DIR).
set CHIP_FLOORPLAN      [expr {[info exists ::env(CHIP_FLOORPLAN)] && $::env(CHIP_FLOORPLAN)}]
if { [info exists ::env(WS_IP_DIR)] } { set WS_IP_DIR $::env(WS_IP_DIR) } else { set WS_IP_DIR "$::env(HOME)/Documents/waferspace_manquehue/ip" }
set CHIP_WS_IPS         {gf180mcu_ws_ip__qrcode_id gf180mcu_ws_ip__shuttle_id gf180mcu_ws_ip__project_id gf180mcu_ws_ip__logo gf180mcu_ws_ip__marker}
set CHIP_DCDC_MACROS    {8_segs_wrapper DB_VCO_wrapper 8seg_DB_routing}
# The chip has its own top (rtl/chip/chip_top.sv, scripts/chip/gen_chip_top.py) and its own library
# CROC_HIER: path of the croc_soc logic in the top (empty for the macro, i_croc/ under chip_top)
set CROC_HIER           ""
if {$CHIP_FLOORPLAN} {
    set TOP_MODULE      "chip_top"
    set DESIGN_NAME     $TOP_MODULE
    set DESIGN_LIBRARY  "chip.dlib"
    set CROC_HIER       "i_croc/"
    # IO library with the related supply pins of the pad pins (make chip_macros_ndm, scripts/chip/create_io_ndm.tcl)
    set io_ndm [lsearch -glob $REFERENCE_LIBRARY *gf180mcu_fd_io.ndm]
    set REFERENCE_LIBRARY [lreplace $REFERENCE_LIBRARY $io_ndm $io_ndm [file normalize [file dirname [info script]]/../../work/gf180mcu_fd_io.ndm]]
}

# -----------------------------------------------------------------------------
# 4. Flow Constraints
# -----------------------------------------------------------------------------
# Oversized and clock cells, not used in the synthesized datapath
set SYN_IGNORE_CELLS    {*/*_12 */*_16 */*_20 */*__clk*}

# Cells allowed in clock tree synthesis
set CTS_CELLS           {*/*clk* */*icg* */*lat* */*dff*}