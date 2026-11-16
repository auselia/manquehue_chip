#!/bin/bash
# Build gls_mini, the 2 KB program of the gate-level simulation: it prints "GLS OK" on the UART
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh
# in:  gls_mini.c, link.ld (LENGTH 2K: lib/link.ld still describes the old 16 KB SRAM)
# out: bin/gls_mini.{elf,dump,hex}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
set_march rv32i_zicsr

for source in "$LIB/crt0.S" gls_mini.c "$LIB/src/uart.c"; do compile "$source"; done
link gls_mini link.ld build/crt0.o build/gls_mini.o build/uart.o -lgcc
sram_image gls_mini
${PFX}size bin/gls_mini.elf
