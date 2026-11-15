# Corners of croc_soc: the PVT of each corner, its library views and its parasitics
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  nothing. Tcl reads this file with source. Bash and Make read it with scripts/lib/config.py.
# out: nothing
#
# Only "set NAME value" lines and comments. Scripts loop over CORNERS and read CORNER_<corner>_<field>.

set CORNERS "slow typical fast"

# Library names. The view of a corner is <SC_LIB>__<CORNER_<corner>_LIB>.db, the same for IO_LIB.
set SC_LIB gf180mcu_fd_sc_mcu7t5v0
set IO_LIB gf180mcu_fd_io
# The PDK has one SRAM view (tt, 25 C, 5.0 V). All corners use it. sram_derate.tcl derates it at slow and fast.
set SRAM_LIB gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00

# The 5 V rail: 4.5, 5.0 and 5.5 V. SPEF is the suffix that write_parasitics gives to the parasitics of the
# corner: <spec>_<temperature>. The PDK has one nxtgrd (typ).
set CORNER_slow_PROCESS     ss
set CORNER_slow_VOLTAGE     4.5
set CORNER_slow_TEMPERATURE 125
set CORNER_slow_LIB         ss_125C_4v50
set CORNER_slow_SPEF        typ_125

set CORNER_typical_PROCESS     tt
set CORNER_typical_VOLTAGE     5.0
set CORNER_typical_TEMPERATURE 25
set CORNER_typical_LIB         tt_025C_5v00
set CORNER_typical_SPEF        typ_25

set CORNER_fast_PROCESS     ff
set CORNER_fast_VOLTAGE     5.5
set CORNER_fast_TEMPERATURE -40
set CORNER_fast_LIB         ff_n40C_5v50
set CORNER_fast_SPEF        typ_-40
