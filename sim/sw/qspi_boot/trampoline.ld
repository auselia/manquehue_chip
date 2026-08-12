/* Copyright (c) 2026 ETH Zurich and University of Bologna.
 * Licensed under the Apache License, Version 2.0, see LICENSE for details.
 *
 * Minimal linker script for trampoline.S -- just places .text at the
 * SRAM base, nothing else needed for a 16-byte, no-stack, no-globals stub.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
	SRAM (rx) : ORIGIN = 0x10000000, LENGTH = 16K
}

SECTIONS
{
	/DISCARD/ : { *(.riscv.attributes) *(.comment) }

	.text : ALIGN(4) { *(.text) } > SRAM
}
