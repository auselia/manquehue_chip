###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Reference library of the chip-level macros (chip floorplan, CHIP_FLOORPLAN=1)
###############################################################################
# lm_shell script (make chip_macros_ndm). Makes work/chip_macros.ndm, physical views only:
#   - the 5 wafer.space IPs from their LEFs (WS_IP_DIR)
#   - the DC-DC wrappers from the abstracts of dcdc_abstract.py (work/chip_abstracts/*.lef)

source [file dirname [info script]]/../common/setup.tcl

create_workspace -flow physical_only -technology $TECH_FILE chip_macros

foreach ip $CHIP_WS_IPS {
    read_lef $WS_IP_DIR/$ip/lef/$ip.lef
}
foreach m $CHIP_DCDC_MACROS {
    read_lef chip_abstracts/$m.lef
}

check_workspace -allow_missing
commit_workspace -force -output chip_macros.ndm
