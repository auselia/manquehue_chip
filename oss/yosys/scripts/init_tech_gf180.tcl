# Technology setup for gf180mcu_fd_sc_mcu7t5v0 (5 V, variant D). All paths relative to oss/yosys/.
# Environment from oss/env.sh: STD_LIB_DIR, SRAM_LIB_DIR, SCL.

set scl $::env(SCL)
set tech_cells [list "$::env(STD_LIB_DIR)/lib/${scl}__tt_025C_5v00.lib"]

# the SRAM macro is read as a port-only blackbox (oss/build/sram_blackbox.v), its liberty is for reports only
set tech_macros [list "$::env(SRAM_LIB_DIR)/lib/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.lib"]

# for hilomap: {cell pin}
set tech_cell_tiehi [list ${scl}__tieh Z]
set tech_cell_tielo [list ${scl}__tiel ZN]

set lib_list [concat $tech_cells $tech_macros]
set liberty_args [list]
foreach lib $lib_list { lappend liberty_args -liberty $lib }
set tech_cells_args [list]
foreach lib $tech_cells { lappend tech_cells_args -liberty $lib }

foreach file $tech_cells { yosys read_liberty -lib $file }
yosys read_verilog -lib [file normalize "../build/sram_blackbox.v"]

# Cells ABC and dfflibmap must not use: same intent as SYN_IGNORE_CELLS of the Fusion Compiler flow
# ({*_12 *_16 *_20 *__clk*}) plus the cells that are not logic (fill, tap, antenna, delay, hold).
set dont_use_list [list]
foreach f $tech_cells {
    set fh [open $f r]
    while {[gets $fh line] >= 0} {
        if {[regexp {^\s*cell\s*\(\s*([A-Za-z0-9_]+)\s*\)} $line -> cell]} {
            if {[regexp {__(buf|inv|and\d|or\d|nand\d|nor\d|xor\d|xnor\d|mux\d|aoi\d+|oai\d+|addf|addh|dff\w*|sdff\w*|lat\w*|icg\w*)_(12|16|20)$} $cell] \
                || [regexp {__(clkbuf|clkinv)_} $cell] \
                || [regexp {__(antenna|endcap|filltie|fill_\d+|fillcap_\d+|hold|dly[a-d]_\d+)$} $cell]} {
                lappend dont_use_list $cell
            }
        }
    }
    close $fh
}
set dont_use_args [list]
foreach cell $dont_use_list { lappend dont_use_args -dont_use $cell }
puts "dont_use cells: [llength $dont_use_list]"
