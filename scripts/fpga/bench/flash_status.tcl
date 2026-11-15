# Reads the W25Q status registers 1, 2, 3 through croc's QSPI command engine (0x2200_2000), from OpenOCD:
#   openocd -f ../openocd-croc.cfg -f flash_status.tcl
# Same register use as s2b_flasher.c: CTRL = EN, mode 0, SCLK clk/4, CS_SETUP 1. QCTRL [1:0] = 0 selects the flash.
set QC 0x22002000
proc qcmd {tx} {
    global QC
    set n [llength $tx]
    mww [expr {$QC + 0x20}] [expr {[read_memory [expr {$QC + 0x20}] 32 1] & ~3}]
    mww [expr {$QC + 0x08}] $n
    foreach b $tx { mww [expr {$QC + 0x0C}] $b }
    sleep 10
    set rx {}
    for {set i 0} {$i < $n} {incr i} { lappend rx [format 0x%02x [expr {[read_memory [expr {$QC + 0x0C}] 32 1] & 0xff}]] }
    mww [expr {$QC + 0x14}] 1
    return $rx
}
halt
mww [expr {$QC + 0x00}] [expr {1 | (1 << 8) | (1 << 16)}]
echo "JEDEC [qcmd {0x9f 0 0 0}]"
echo "SR1 [qcmd {0x05 0}]"
echo "SR2 [qcmd {0x35 0}]"
echo "SR3 [qcmd {0x15 0}]"
shutdown
