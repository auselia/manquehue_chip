# Technology setup for gf180mcu_fd_sc_mcu7t5v0 (variant D, 5LM), three corners as in the FC flow:
#   slow = ss 125C 4.5 V, typical = tt 25C 5.0 V, fast = ff -40C 5.5 V.
# Environment from oss/env.sh: STD_LIB_DIR, SRAM_LIB_DIR, SCL, PDK_DIR.
set scl $::env(SCL)
define_corners slow typical fast

set corner_tags {slow ss_125C_4v50 typical tt_025C_5v00 fast ff_n40C_5v50}
foreach {corner tag} $corner_tags {
    read_liberty -corner $corner "$::env(STD_LIB_DIR)/lib/${scl}__${tag}.lib"
    read_liberty -corner $corner "$::env(SRAM_LIB_DIR)/lib/gf180mcu_fd_ip_sram__sram512x8m8wm1__${tag}.lib"
}

# stage 01 starts from the netlist and needs the LEFs; later stages read the db, which carries them
if {![info exists read_lefs] || $read_lefs} {
    read_lef "$::env(STD_LIB_DIR)/techlef/${scl}__nom.tlef"
    read_lef "$::env(STD_LIB_DIR)/lef/${scl}.lef"
    read_lef "$::env(SRAM_LIB_DIR)/lef/gf180mcu_fd_ip_sram__sram512x8m8wm1.lef"
}

set site_name  GF018hv5v_mcu_sc7
set sram_cell  gf180mcu_fd_ip_sram__sram512x8m8wm1

# wire RC for estimate_parasitics before routing (values of the PDK's librelane config / ORFS gf180 setRC)
proc setDefaultParasitics {} {
    set_layer_rc -layer Metal1 -resistance 8.929E-04 -capacitance 1.0E-04
    set_layer_rc -layer Metal2 -resistance 3.85861E-04 -capacitance 1.35357E-04
    set_layer_rc -layer Metal3 -resistance 2.06673E-04 -capacitance 1.46141E-04
    set_layer_rc -layer Metal4 -resistance 1.68609E-04 -capacitance 1.50688E-04
    set_layer_rc -layer Metal5 -resistance 7.92778E-05 -capacitance 1.55595E-04
    set_layer_rc -via Via1 -resistance 4.23
    set_layer_rc -via Via2 -resistance 4.23
    set_layer_rc -via Via3 -resistance 4.23
    set_layer_rc -via Via4 -resistance 4.23
    set_wire_rc -signal -layer Metal3
    set_wire_rc -clock  -layer Metal4
}

set tieHiPin "${scl}__tieh/Z"
set tieLoPin "${scl}__tiel/ZN"
set ctsBuf     [list ${scl}__clkbuf_2 ${scl}__clkbuf_4 ${scl}__clkbuf_8 ${scl}__clkbuf_16]
set ctsBufRoot ${scl}__clkbuf_16
set tapCell    ${scl}__filltie
set endCap     ${scl}__endcap
# PDK's pnr_exclude.cells (cells the PDK does not want in place and route) plus the delay cells
set dont_use_cells [list ${scl}__mux2_1 ${scl}__oai33_2 ${scl}__dly* ${scl}__hold ${scl}__antenna]
