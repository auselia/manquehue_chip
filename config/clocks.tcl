# Clocks of croc_soc: periods, clock uncertainty and the budget outside the macro (times in ns)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  nothing. Tcl reads this file with source. Bash and Make read it with scripts/lib/config.py.
# out: nothing
#
# Only "set NAME value" lines and comments.

# The optimizer implements CLOCK_PERIOD. Sign-off is at SPEC_PERIOD (AUS-9). The optimizer stops about 1.4 ns
# short of each period it gets, so a netlist implemented at 50 ns closes at 55 ns.
set CLOCK_PORT_NAME clk_i
set CLOCK_PERIOD    50.0
set SPEC_PERIOD     55.0

# JTAG test clock (10 MHz). The debug probe drives it from outside the chip.
set JTAG_TCK_PORT   jtag_tck_i
set JTAG_TCK_PERIOD 100.0

# Clock uncertainty of clock and adc_sclk. Before CTS, the setup value includes the clock skew of the v0.1 clock
# QoR report. From CTS on (04_cts.tcl), the tree is real and SETUP_UNCERT_CTS applies. Sign-off uses it too.
set SETUP_UNCERT     2.75
set SETUP_UNCERT_CTS 0.7
set HOLD_UNCERT      0.25
# TCK is slow and comes from outside the chip: fixed margins.
set JTAG_SETUP_UNCERT 2.0
set JTAG_HOLD_UNCERT  0.5

# Hold uncertainty while 04_cts.tcl to 06_finish.tcl implement: 0.1 ns more than sign-off. At the SRAM clock pins
# it is 0.2 ns more, because PrimeTime finds about 0.1 ns less hold slack there than Fusion Compiler. 0.4 ns more
# filled the channel between the SRAMs with hold buffers (5935 routing DRCs). export_signoff.tcl writes the
# sign-off values.
set HOLD_UNCERT_IMPL      0.35
set JTAG_HOLD_UNCERT_IMPL 0.6
set SRAM_HOLD_UNCERT_IMPL 0.45

# Ideal clock transition before CTS (an estimate).
set CLOCK_IDEAL_TRAN 0.4

# Outside the macro. IO_DELAY_FRAC is the fraction of the period for the pad (3 ns in, 7 to 12 ns out,
# gf180mcu_fd_io) and the board. EXT_INPUT_TRAN is the slew of the input pad Y pin into the macro. EXT_LOAD (pF)
# is the pad A pin plus the wire from the macro to the pad. The last two are estimates, not liberty values.
set IO_DELAY_FRAC  0.20
set EXT_INPUT_TRAN 0.3
set EXT_LOAD       0.2
