// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
//
// SRAM-resident QSPI boot trampoline. Placed at 0x1000_0000 (SRAM base --
// also soc_ctrl's BOOTADDR reset default), so bootrom's normal boot path
// lands here with zero register writes needed. Byte-identical to the
// existing qspi_boot_trampoline.hex in this directory; written as raw
// .word encodings (not mnemonics) specifically so it stays byte-for-byte
// identical to that already-proven file.

.section .text
.globl _start
_start:
    .word 0x200002B7   /* lui t0, 0x20000 */
    .word 0x00028067   /* jr  t0          */
1:
    .word 0x0000006F   /* j . -- defined filler word for the prefetcher */
    .word 0x0000006F   /* j . */
