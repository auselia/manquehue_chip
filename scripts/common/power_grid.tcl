###############################################################################
# Croc SoC Physical Design Flow (Block Level)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Power Grid Creation and Connection (INCREMENTAL)
###############################################################################

##############################################################
# Reset grid & Connect Nets
##############################################################
remove_pg_strategies -all
remove_pg_patterns -all
remove_pg_regions -all
remove_pg_via_master_rules -all
remove_pg_strategy_via_rules -all
remove_routes -net_types {power ground} -ring -stripe -macro_pin_connect -lib_cell_pin_connect

create_net -power VDD
create_net -ground VSS

set all_macros [get_cells -hierarchical -filter "is_hard_macro && !is_physical_only && ref_name =~ gf180mcu_fd_ip_sram__*"]

connect_pg_net -net VDD [get_pins -of_objects $all_macros -physical_context -filter "name == VDD"]
connect_pg_net -net VSS [get_pins -of_objects $all_macros -physical_context -filter "name == VSS"]

connect_pg_net -automatic

# Chip floorplan: supply pins of the pad ring (common/chip_pg_pads.tcl)
if {$CHIP_FLOORPLAN} {
    source [file dirname [info script]]/chip_pg_pads.tcl
    chip_connect_pads
}

# V3.2b/V4.2b: cuts in a 4x4 or larger array need 0.36 um spacing (default is the 0.26 um minimum)
set PG_VIA_CUT_SPACING {0.36 0.36}
set_pg_via_master_rule via_master_mesh_top -contact_code Via4_VV -cut_spacing $PG_VIA_CUT_SPACING
set_pg_via_master_rule via_master_sram_v3 -contact_code Via3_VV -cut_spacing $PG_VIA_CUT_SPACING
set_pg_via_master_rule via_master_sram_v4 -contact_code Via4_VV -cut_spacing $PG_VIA_CUT_SPACING

##############################################################
# 1. Power Ring around Design Boundary
##############################################################
create_pg_ring_pattern main_ring_pattern -nets {VDD VSS} \
    -horizontal_layer Metal5 -horizontal_width 10 -horizontal_spacing 2 \
    -vertical_layer Metal4   -vertical_width 10   -vertical_spacing 2 \
    -via_rule {{intersection: adjacent} {via_master: via_master_mesh_top}}

set_pg_strategy main_ring_strategy -core -pattern {{pattern: main_ring_pattern} {nets: {VDD VSS}} {offset: {2 2}}}

# ---> COMPILE STEP 1
compile_pg -strategies main_ring_strategy

# Chip floorplan: straps from the inner-edge pins of the CROC power pads (Metal2 on DVDD/DVSS, Metal3 on the
# rotated west and east pads) to the ring of the same net: VDD to the inner ring, VSS to the outer one
if {$CHIP_FLOORPLAN} {
    # The strap vias are large arrays: V2.2b/V3.2b/V4.2b want the 0.36 um cut spacing (PG_VIA_CUT_SPACING)
    set_pg_via_master_rule via_master_pad_v2 -contact_code Via2_HH -cut_spacing $PG_VIA_CUT_SPACING
    set_pg_via_master_rule via_master_pad_v3 -contact_code Via3_HH -cut_spacing $PG_VIA_CUT_SPACING
    set_pg_via_master_rule via_master_pad_v4 -contact_code Via4_HH -cut_spacing $PG_VIA_CUT_SPACING
    create_pg_macro_conn_pattern croc_pad_conn -pin_conn_type scattered_pin -nets {VDD VSS} \
        -layers {Metal3 Metal2} -width 10 \
        -via_rule {{intersection: all} {via_master: {via_master_pad_v2 via_master_pad_v3 via_master_pad_v4}}}
    set_pg_strategy croc_pad_strategy -macros [get_cells {pad_CROC_vdd_* pad_CROC_vss_*}] \
        -pattern {{pattern: croc_pad_conn} {nets: {VDD VSS}}} -extension {{stop: innermost_ring}}
    # vias between the straps and the existing ring, with the same spaced masters
    set_pg_strategy_via_rule croc_pad_to_ring -via_rule { \
        {{{strategies: croc_pad_strategy}} {{existing: ring}} \
         {via_master: {via_master_pad_v2 via_master_pad_v3 via_master_pad_v4}}} \
        {{{strategies: croc_pad_strategy}} {{macro_pins: all}} \
         {via_master: {via_master_pad_v2 via_master_pad_v3 via_master_pad_v4}}} \
    }
    compile_pg -strategies croc_pad_strategy -via_rule croc_pad_to_ring
}

##############################################################
# 2. Macro Scattered Pins Connection (SRAMs)
##############################################################
create_pg_ring_pattern sram_inner_ring_pat \
    -nets {VDD VSS} \
    -horizontal_layer Metal5 \
    -vertical_layer Metal4 \
    -horizontal_width 2.0 \
    -vertical_width 2.0 \
    -horizontal_spacing 1.0 \
    -vertical_spacing 1.0 \
    -corner_bridge true

set_pg_strategy sram_inner_ring_strat \
    -macros $all_macros \
    -pattern {{name: sram_inner_ring_pat} {nets: {VDD VSS}} {offset: {-5.0 -5.0}}}

set_pg_strategy_via_rule ring_to_macro_vias \
    -via_rule { \
        {{{strategies: sram_inner_ring_strat}} \
         {{macro_pins: all} {layers: Metal3}} \
         {via_master: {via_master_sram_v3 via_master_sram_v4}}} \
         \
        {{{strategies: sram_inner_ring_strat}} \
         {{macro_pins: all} {layers: Metal3}} \
         {via_master: {via_master_sram_v3 via_master_sram_v4}} \
         {between_parallel: true}} \
    }

compile_pg -strategies {sram_inner_ring_strat} -via_rule {ring_to_macro_vias}

##############################################################
# 3. Global Power Mesh
##############################################################
create_pg_mesh_pattern mesh_pattern_top -via_rule {{intersection: adjacent} {via_master: via_master_mesh_top}} \
    -layers { \
        {{horizontal_layer: Metal5 } {width: 3} {pitch: 40} {spacing: interleaving} } \
        {{vertical_layer:   Metal4 } {width: 3} {pitch: 40} {spacing: interleaving} } \
}

set_pg_strategy mesh_strategy_top -core \
    -pattern {{pattern: mesh_pattern_top} {nets: {VDD VSS}}} \
    -extension {stop: innermost_ring} \
    -blockage [list [list {macros_with_keepout: $all_macros} "layers: Metal1"]]

set_pg_strategy_via_rule via_mesh_to_ring -via_rule { \
    {{{strategies: mesh_strategy_top}} \
     {{existing: ring} {layers: { Metal5 Metal4 }} } \
     {via_master: via_master_mesh_top}}
}

compile_pg -strategies mesh_strategy_top -via_rule via_mesh_to_ring

##############################################################
# 4. Std rail
##############################################################
create_pg_std_cell_conn_pattern M1_rail -layers {Metal1}

set_pg_strategy M1_rail_strategy -core -pattern {{name: M1_rail} {nets: VDD VSS}} \
  -blockage {{nets:VDD VSS} {macros_with_keepout: $all_macros}}

set_pg_via_master_rule via_to_stdcells -via_array_dimension {3 1}

set_pg_strategy_via_rule via_rail_to_mesh -via_rule { \
    {{{strategies: M1_rail_strategy} {layers: Metal1}} \
     {{existing: strap} {layers: Metal4}} \
     {via_master: via_to_stdcells}} \
}

compile_pg -strategies M1_rail_strategy -via_rule via_rail_to_mesh

##############################################################
# Verification
##############################################################
check_pg_missing_vias
check_pg_drc -ignore_std_cells
check_pg_connectivity -check_std_cell_pins none
