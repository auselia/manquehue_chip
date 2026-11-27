# Settings of the Fusion Compiler flow: design, PDK files, reference libraries, DRC ECO decks, power pins
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source by every step (through open_lib.tcl), and by make open_<step>
# in:  config/design.tcl, corners.tcl, clocks.tcl, env PDK_ROOT, PDK_SYNOPSYS, SRAM_GDS_DIR
# out: variables
# Design, corners, libraries and clocks: config/, which the check scripts read too. The constraints are in config/sdc/.
set CONFIG_DIR [file normalize [file join [file dirname [info script]] .. .. .. config]]
source $CONFIG_DIR/design.tcl
source $CONFIG_DIR/corners.tcl
source $CONFIG_DIR/clocks.tcl
set DESIGN_NAME         $TOP_MODULE
set DESIGN_LIBRARY      "design.dlib"

# The two PDK folders, with the defaults of scripts/utils/env.sh: the ciel PDK and the Synopsys technology data
proc env_or {name default} { if {[info exists ::env($name)]} { return $::env($name) }; return $default }
set PDK_ROOT     [env_or PDK_ROOT $::env(HOME)/.ciel]
set PDK_SYNOPSYS [env_or PDK_SYNOPSYS $::env(HOME)/pdk_synopsys]

# Sign-off DRC ECOs (drc_eco.tcl): the wafer.space KLayout deck and its routing-rule decks.
set KLAYOUT_BIN         "/nix/store/dljmpck53kb6zxhvd73b688286b0kwkn-klayout-0.30.9/bin/klayout"
set DRC_DECK            "$PDK_ROOT/gf180mcuD/libs.tech/klayout/tech/drc/gf180mcu.drc"
set DRC_ECO_DECKS       "via,metal,contact"
set DRC_ECO_MAX_PASSES  5

# The power pins are the ends of the mesh stripes at the west, east (Metal5) and south (Metal4) edges, this long (um).
# In the LEF, Metal4 and Metal5 stay open in this band, and signal routing stays out of it (02_floorplan.tcl).
set PG_PIN_BAND 5

# PDK and technology files

set STDCELL_TRACK_SIZE  7
set TECHNOLOGY          "gf180mcu"

set PDK_DIR             $PDK_SYNOPSYS
# The official SRAM layouts of the ciel PDK (06_finish.tcl). SRAM_GDS_DIR overrides the folder.
set SRAM_GDS_DIR [env_or SRAM_GDS_DIR $PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_ip_sram/gds]
set TECH_FILE           "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_${STDCELL_TRACK_SIZE}t_mw.tf"
set ICC2GDS_LAYERMAP    "${PDK_DIR}/tech/gf180nm_mcu_5LM_1TM_11K_icc2gds.layermap"

set LPE_LAYERMAP        "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.layermap"
set LPE_NXTGRD          "${PDK_DIR}/pex/gf180mcu_1p5m_1tm_11k_sp_smim_OPTB_typ.nxtgrd"
set LPE_SPEC            "typ"

# Reference libraries (NDM)
# Standard cells, IO cells and the SRAM macro
set REFERENCE_LIBRARY [list \
    "${PDK_DIR}/ndm/gf180mcu_fd_sc_mcu${STDCELL_TRACK_SIZE}t5v0.ndm" \
    "${PDK_DIR}/ndm/gf180mcu_fd_io.ndm" \
    "${PDK_DIR}/ndm/gf180mcu_fd_ip_sram__sram512x8m8wm1.ndm" \
]

# The macro outline, and its lower-left corner in the AC3E die (the pins face their pads from there, 02_floorplan.tcl)
# The top stays at 2202.32: the DC-DC layouts start there (and in DCDC_KEEPOUTS).
set CROC_MACRO_SIZE     {1120 1810}
set CROC_MACRO_LL       {392 392}
# Free core margin (um) in the order of initialize_floorplan -core_offset: left, top, right, bottom (checked on the
# floorplan of 2026-11-25). No ring, so the mesh runs to the edge. The top keeps 25 um: the DC-DC Metal2 runs in that
# band (y 2177.32 to 2202.32).
set CROC_CORE_OFFSET    {5 25 5 5}
# The SRAMs stay this far (um) from the west, east and south edges: their own ring (5 um outside each SRAM) stays out
# of the power pin band.
set SRAM_EDGE_MARGIN    15
# Metal1 to Metal3 of the DC-DC Channels_wrapper inside the croc outline, in die coordinates {llx lly urx ury}, 1 um
# larger than the shapes (measured 2026-11-25 on macros/dcdc/Channels_wrapper.gds). No cells and no Metal1 to Metal3
# routing of croc there (02_floorplan.tcl).
set DCDC_KEEPOUTS       {{391 2124.36 413.63 2203.32} {391 2177.32 1332.32 2203.32}}

# Cells for synthesis and CTS
# Oversized and clock cells, not used in the synthesized datapath
set SYN_IGNORE_CELLS    {*/*_12 */*_16 */*_20 */*__clk*}

# Cells allowed in clock tree synthesis
set CTS_CELLS           {*/*clk* */*icg* */*lat* */*dff*}