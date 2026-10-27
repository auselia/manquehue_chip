###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: gf180mcu_fd_io reference library with related supply pins (chip floorplan, CHIP_FLOORPLAN=1)
###############################################################################
# lm_shell script (make chip_macros_ndm). Makes work/gf180mcu_fd_io.ndm from the 5 V liberty corners and the PDK
# LEFs, with the related supply pins of the pad pins. ${TECHLIB_DATA_DIR}/ndm/gf180mcu_fd_io.ndm has none: compile_fusion
# reports MV-223 and does not buffer there. Method of the PDK example adder_plus_pads_fc_shell/scripts/create_ndm_io_lib.tcl.

source [file dirname [info script]]/../common/setup.tcl

set_app_options -name lib.setting.use_tech_scale_factor -value true
set_app_options -name lib.workspace.keep_all_physical_cells -value true
set_app_options -name lib.logic_model.auto_remove_timing_only_designs -value true

create_workspace -technology $TECH_FILE gf180mcu_fd_io

# the corners of mcmm.tcl: process labels ss, tt, ff
foreach {db label} {gf180mcu_fd_io__ss_125C_4v50.db ss gf180mcu_fd_io__tt_025C_5v00.db tt gf180mcu_fd_io__ff_n40C_5v50.db ff} {
    read_db ${TECHLIB_DATA_DIR}/db/$db -process_label $label
}
read_lef [glob $::env(HOME)/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_io/lef/gf180mcu_fd_io__*.lef]

set_attribute [get_layers {Metal1 Metal3 Metal5}] routing_direction horizontal
set_attribute [get_layers {Metal2 Metal4}] routing_direction vertical
set_attribute [get_lib_cells */*io__brk*] -name design_type -value pad_spacer

# Core-side pins on VDD/VSS, the pad pin on DVDD/DVSS
foreach c {gf180mcu_fd_io__bi_t gf180mcu_fd_io__bi_24t gf180mcu_fd_io__in_c gf180mcu_fd_io__in_s} {
    set_attribute [get_lib_pins */$c/VDD]  -name port_type -value power
    set_attribute [get_lib_pins */$c/DVDD] -name port_type -value power
    set_attribute [get_lib_pins */$c/VSS]  -name port_type -value ground
    set_attribute [get_lib_pins */$c/DVSS] -name port_type -value ground
    foreach p {Y A IE OE CS PU PD SL PDRV1 PDRV0} {
        set lp [get_lib_pins -quiet */$c/$p]
        if {[sizeof_collection $lp] == 0} { continue }
        set_attribute $lp -name related_power_pin_name  -value VDD
        set_attribute $lp -name related_ground_pin_name -value VSS
    }
    set_attribute [get_lib_pins */$c/PAD] -name related_power_pin_name  -value DVDD
    set_attribute [get_lib_pins */$c/PAD] -name related_ground_pin_name -value DVSS
}

check_workspace -allow_missing
commit_workspace -force -output gf180mcu_fd_io.ndm
