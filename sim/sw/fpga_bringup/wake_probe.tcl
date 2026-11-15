# WAKE_N through croc's ADC block (0x2200_0100): clear the sticky WAKE flag (STATUS[6]), wait, read it, and sample the
# synchronised pin level (PINS[8]) 20 times. EN and TRIG_ACTIVE_LOW set, reader not running.
#   openocd -f openocd-croc.cfg -f wake_probe.tcl
set A 0x22000100
mww $A [expr {1 | (1 << 14) | (3 << 8)}]
mww [expr {$A + 0x04}] 0x40
sleep 300
set st [read_memory [expr {$A + 0x04}] 32 1]
set low 0
for {set i 0} {$i < 20} {incr i} { if {!([read_memory [expr {$A + 0x20}] 32 1] & 0x100)} { incr low } ; sleep 10 }
echo "WAKE flag [expr {($st >> 6) & 1}] pin_low $low/20"
shutdown
