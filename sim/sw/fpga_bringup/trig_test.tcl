# WAKE_N-triggered ADC capture, set up over JTAG with the core halted (the SRAM above 0x1000_0300 is free then).
# Buffers of 128 samples at 0x1000_0300 and 0x1000_0400 work as one ring, POST = 112: 16 samples before the trigger
# and 112 after it. Waits up to 3 s for DONE, then prints STATUS, TPOS, COUNT and the 128 words of both buffers.
#   openocd -f openocd-croc.cfg -f trig_test.tcl
set A 0x22000100
set B0 0x10000300
set B1 0x10000400
mww $A [expr {1 << 5}]
sleep 1
mww [expr {$A + 0x08}] $B0
mww [expr {$A + 0x0C}] $B1
mww [expr {$A + 0x10}] 128
mww [expr {$A + 0x24}] 112
mww [expr {$A + 0x04}] 0xFF
for {set i 0} {$i < 128} {incr i} { mww [expr {$B0 + 4 * $i}] 0 }
mww $A [expr {1 | 2 | 4 | (2 << 8) | (1 << 12) | (1 << 14)}]
set st 0
for {set i 0} {$i < 30} {incr i} { set st [read_memory [expr {$A + 0x04}] 32 1]; if {$st & 0x20} break; sleep 100 }
echo "STATUS [format 0x%x $st] DONE [expr {($st >> 5) & 1}] WAKE [expr {($st >> 6) & 1}]"
echo "TPOS [format 0x%x [read_memory [expr {$A + 0x28}] 32 1]] COUNT [read_memory [expr {$A + 0x1C}] 32 1]"
echo "B0 [read_memory $B0 32 64]"
echo "B1 [read_memory $B1 32 64]"
mww $A 0
shutdown
