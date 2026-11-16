# Settings of the Fusion Compiler flow: design, PDK files, reference libraries, DRC ECO decks, power pins
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source by every step (through open_lib.tcl), and by make open_<step>
# in:  config/corners.tcl, config/clocks.tcl, env SRAM_GDS_DIR
# out: variables and the proc pg_pins
# Design
set TOP_MODULE          "croc_soc"
set DESIGN_NAME         $TOP_MODULE
set DESIGN_LIBRARY      "design.dlib"

# Corners, libraries and clocks: config/, which the check scripts read too. The constraints are in config/sdc/.
set CONFIG_DIR [file normalize [file join [file dirname [info script]] .. .. .. config]]
source $CONFIG_DIR/corners.tcl
source $CONFIG_DIR/clocks.tcl

# Top-level power pins: {layer llx lly urx ury} in um per net, for an outline W x H. They are the straight parts of
# the PG rings, without the 30 um corner via arrays (power_grid.tcl: VDD 13 to 23 um, VSS 1 to 11 um inside the
# outline). Computed from the outline because the height follows the cell area. 06_finish.tcl checks each pin.
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
set DRC_ECO_MAX_PASSES  5

# Metal4 and Metal5 stay open this far in from the boundary (um) so a parent grid can reach the pins.
set PG_PIN_BAND 25

# PDK and technology files
# Synopsys technology data for GF180MCU
set TECHLIB_DATA_DIR    "/home/navillegas/pdk_synopsys"

set STDCELL_TRACK_SIZE  7
set TECHNOLOGY          "gf180mcu"

set PDK_DIR             $TECHLIB_DATA_DIR
# The official SRAM layouts of the ciel PDK (06_finish.tcl). SRAM_GDS_DIR overrides the folder.
if { [info exists ::env(SRAM_GDS_DIR)] } { set SRAM_GDS_DIR $::env(SRAM_GDS_DIR) } else { set SRAM_GDS_DIR "$::env(HOME)/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram/gds" }
set TECH_FILE           "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_${STDCELL_TRACK_SIZE}t_mw.tf"
set ICC2GDS_LAYERMAP    "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_icc2gds.layermap"

set LPE_LAYERMAP        "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.layermap"
set LPE_NXTGRD          "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.nxtgrd"
set LPE_SPEC            "typ"

# Reference libraries (NDM)
# Standard cells, IO cells and the SRAM macro
set REFERENCE_LIBRARY [list \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_sc_mcu${STDCELL_TRACK_SIZE}t5v0.ndm" \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_io.ndm" \
    "${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_ip_sram__sram512x8m8wm1.ndm" \
]

# The macro outline, and its lower-left corner in the AC3E die (the pins face their pads from there, 02_floorplan.tcl)
set CROC_MACRO_SIZE     {1120 1800}
set CROC_MACRO_LL       {392 404}

# Cells for synthesis and CTS
# Oversized and clock cells, not used in the synthesized datapath
set SYN_IGNORE_CELLS    {*/*_12 */*_16 */*_20 */*__clk*}

# Cells allowed in clock tree synthesis
set CTS_CELLS           {*/*clk* */*icg* */*lat* */*dff*}