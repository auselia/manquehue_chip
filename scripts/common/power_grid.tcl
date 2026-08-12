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

set all_macros [get_cells -hierarchical -filter "is_hard_macro && !is_physical_only"]

connect_pg_net -net VDD [get_pins -of_objects $all_macros -physical_context -filter "name == VDD"]
connect_pg_net -net VSS [get_pins -of_objects $all_macros -physical_context -filter "name == VSS"]

connect_pg_net -automatic

set_pg_via_master_rule via_master_mesh_top -contact_code Via4_VV

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
         {via_master: {Via3_VV Via4_VV}}} \
         \
        {{{strategies: sram_inner_ring_strat}} \
         {{macro_pins: all} {layers: Metal3}} \
         {via_master: {Via3_VV Via4_VV}} \
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
