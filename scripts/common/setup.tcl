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
set CLOCK_PERIOD        55.0

# -----------------------------------------------------------------------------
# 2. PDK & Technology Paths
# -----------------------------------------------------------------------------
# Hardcoded path to Synopsys technology data for GF180MCU
set TECHLIB_DATA_DIR    "/home/navillegas/pdk_synopsys"

set STDCELL_TRACK_SIZE  7
set TECHNOLOGY          "gf180mcu"

# Tech Files & Layermaps
set PDK_DIR             $TECHLIB_DATA_DIR
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