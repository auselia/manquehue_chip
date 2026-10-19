# Startup of a program that runs from the QSPI flash (link_flash.ld).
# The bootrom has cleared the registers, set mtvec to its trap handler and jumped here with ra = _eoc.
# - gp and sp
# - trap handler pointers at 0x1000_0004 (exception) and 0x1000_0008 (interrupt), read by the bootrom handler
# - .data copied from the flash to the SRAM, .bss cleared
# - tail call of main: ra still points to _eoc, so the return value of main reaches CORESTATUS

.globl _start
.section .text._start, "ax", @progbits
_start:
  .option push
  .option norelax
  la      gp, __global_pointer$
  .option pop
  la      sp, __stack_pointer$

  li      t0, 0x10000000
  la      t1, croc_exception_handler
  sw      t1, 4(t0)
  la      t1, croc_interrupt_handler
  sw      t1, 8(t0)

  la      t0, __data_load
  la      t1, __data_start
  la      t2, __data_end
1:
  bgeu    t1, t2, 2f
  lw      t3, 0(t0)
  sw      t3, 0(t1)
  addi    t0, t0, 4
  addi    t1, t1, 4
  j       1b
2:
  la      t1, __bss_start
  la      t2, __bss_end
3:
  bgeu    t1, t2, 4f
  sw      zero, 0(t1)
  addi    t1, t1, 4
  j       3b
4:
  tail    main

# Default handlers (weak, override in C)
.section .text
.weak croc_exception_handler
.globl croc_exception_handler
croc_exception_handler:
  ret

.weak croc_interrupt_handler
.globl croc_interrupt_handler
croc_interrupt_handler:
  ret
