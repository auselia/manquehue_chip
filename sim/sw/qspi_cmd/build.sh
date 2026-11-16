#!/bin/bash
# Build the test of the QSPI command engine for the 2 KB SRAM (RTL simulation, or over JTAG on the ZedBoard)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh      (env: DEFS, NAME (the output name, default qspi_cmd_test))
# in:  qspi_cmd_test.c, the linker script of gls_mini
# out: bin/<name>.{elf,dump,hex}
#
# Compressed instructions (rv32ic): with rv32i the code does not fit below the stack. The CVE2 core has the C extension.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
use_soft_float_gcc
set_march rv32ic_zicsr
program=${NAME:-qspi_cmd_test}

compile "$LIB/crt0.S"
compile "$LIB/src/uart.c"
# shellcheck disable=SC2086  # DEFS is a list of options
compile qspi_cmd_test.c "$program" -- ${DEFS:-}
link "$program" ../gls_mini/link.ld build/crt0.o "build/$program.o" build/uart.o -lgcc
sram_image "$program"
${PFX}size "bin/$program.elf"
check_end "$program" 0x10000700 "the stack (256 B at the top of the SRAM)"
