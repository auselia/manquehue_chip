#!/bin/bash
# Build the ZedBoard FFT and LoRa demo for the 2 KB SRAM, loaded over JTAG (see README.md)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh      (env: DEFS, for example -DFRF=0xD90000u (868 MHz) or "-DCLK_HZ=20000u -DNPKT=2" (simulation),
#        NAME (the output name, default fft_lora))
# in:  fft_lora.c, the linker script of gls_mini
# out: bin/<name>.{elf,dump,hex}
#
# Compressed instructions (rv32ic): with rv32i the code does not fit next to the 256 B sample buffer and the stack.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
use_soft_float_gcc
set_march rv32ic_zicsr
program=${NAME:-fft_lora}

compile "$LIB/crt0.S"
compile "$LIB/src/uart.c"
# shellcheck disable=SC2086  # DEFS is a list of options
compile fft_lora.c "$program" -- ${DEFS:-}
link "$program" ../gls_mini/link.ld build/crt0.o "build/$program.o" build/uart.o -lgcc
sram_image "$program"
${PFX}size "bin/$program.elf"
sample_buffer=$(sed -n 's/^#define BUF \(0x[0-9a-fA-F]*\)u.*/\1/p' fft_lora.c)
check_end "$program" "$sample_buffer" "the sample buffer"
