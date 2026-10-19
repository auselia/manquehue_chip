# 32-bit multiply for the CVE2 core without a multiplier (RV32MNone): the shift-and-add loop of libgcc
# (libgcc/config/riscv/muldi3.S for XLEN 32). It is here because the libgcc of the nix toolchain on Rocky
# (riscv32-none-elf-gcc) is built for rv32gc only: it does not link with ilp32 objects, and its multiply
# would use the mul instruction.
  .section .text.__mulsi3, "ax", @progbits
  .globl __mulsi3
  .type  __mulsi3, @function
__mulsi3:
  mv   a2, a0
  li   a0, 0
1:
  andi a3, a1, 1
  beqz a3, 2f
  add  a0, a0, a2
2:
  srli a1, a1, 1
  slli a2, a2, 1
  bnez a1, 1b
  ret
  .size __mulsi3, .-__mulsi3
