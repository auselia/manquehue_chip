/* Programs that run from the QSPI flash (execute in place), data in the 2 KB SRAM.
 *
 * Flash image (0x2000_0000):  magic word "CROC" (0x434F5243), _start at 0x2000_0004 (the bootrom jumps there
 *                              when it finds the magic), code, read-only data, initial values of .data
 * SRAM (0x1000_0000, 2 KB):    function pointer table of the bootrom trap handler (+4 exception, +8 interrupt,
 *                              written by crt0_flash.S), .data, .bss, stack at the top
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
	FLASH (rx)  : ORIGIN = 0x20000000, LENGTH = 16M
	SRAM  (rwx) : ORIGIN = 0x10000000, LENGTH = 2K
}

PHDRS
{
	text PT_LOAD FLAGS(5);
	data PT_LOAD FLAGS(6);
}

SECTIONS
{
	/DISCARD/ :
	{
	*(.riscv.attributes)
	*(.comment)
	}

	/* image magic, read by the bootrom */
	.flash_header :
	{
	LONG(0x434F5243)
	} > FLASH :text

	/* entry point right after the magic */
	.text._start : ALIGN(4)
	{
	KEEP(*(.text._start))
	} > FLASH :text

	.text : ALIGN(4)
	{
	*(.text)
	*(.text.*)
	*(.rodata)
	*(.rodata.*)
	*(.srodata)
	*(.srodata.*)
	} > FLASH :text

	/* SRAM: the bootrom reads the trap handler pointers at 0x1000_0004 and 0x1000_0008 */
	.sram_vectors (NOLOAD) :
	{
	. = . + 12;
	} > SRAM :data

	.data : ALIGN(4)
	{
	__data_start = .;
	*(.sdata)
	*(.sdata.*)
	*(.data)
	*(.data.*)
	. = ALIGN(4);
	__data_end = .;
	} > SRAM AT> FLASH :data
	__data_load = LOADADDR(.data);

	.bss (NOLOAD) : ALIGN(4)
	{
	__bss_start = .;
	*(.sbss)
	*(.sbss.*)
	*(.bss)
	*(.bss.*)
	*(COMMON)
	. = ALIGN(4);
	__bss_end = .;
	} > SRAM :data
}

ASSERT(ADDR(.text._start) == 0x20000004, "_start must follow the image magic at 0x2000_0004")

/* GP in the middle of the SRAM, so every SRAM address is within its +-2 KB reach */
PROVIDE(__global_pointer$ = ORIGIN(SRAM) + LENGTH(SRAM) / 2);
PROVIDE(__stack_pointer$ = ORIGIN(SRAM) + LENGTH(SRAM));

/* Bootrom symbols (fixed addresses) */
PROVIDE(_eoc = 0x02000100);
PROVIDE(_trap_handler_wrapper = 0x02000200);
PROVIDE(_trap_exit = 0x02000300);

/* SoC register symbols */
PROVIDE(corestatus = 0x03000008);
