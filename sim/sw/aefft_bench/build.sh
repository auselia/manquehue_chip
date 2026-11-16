#!/bin/bash
# Build the AE-FFT benchmark (the accelerator against software) for the 2 KB SRAM
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh      (env: MARCH (default rv32ic_zicsr), TAG (suffix of the output name), DEFS, REGEN=1)
# in:  main.c, mulsi3.S, bench.h (gen_header.py writes it when it is missing or with REGEN=1, needs numpy)
# out: bin/aefft_bench${TAG}.{elf,dump,hex}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
set_march "${MARCH:-rv32ic_zicsr}"
program=aefft_bench${TAG:-}

if [ -n "${REGEN:-}" ] || [ ! -f bench.h ]; then python3 gen_header.py; fi
# shellcheck disable=SC2086  # DEFS is a list of options
for source in "$LIB/crt0.S" main.c mulsi3.S "$LIB/src/uart.c"; do compile "$source" -- ${DEFS:-}; done
link "$program" link.ld build/crt0.o build/main.o build/mulsi3.o build/uart.o
sram_image "$program"
${PFX}size "bin/$program.elf"
