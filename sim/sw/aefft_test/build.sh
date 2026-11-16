#!/bin/bash
# Build the AE-FFT system test for the 2 KB SRAM
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh
# in:  main.c, the test vectors of sim/fft (gen_fw_header.py writes vectors.h)
# out: bin/aefft_test.{elf,dump,hex}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
set_march rv32i_zicsr

python3 ../../fft/gen_fw_header.py
for source in "$LIB/crt0.S" main.c "$LIB/src/uart.c"; do compile "$source"; done
link aefft_test link.ld build/crt0.o build/main.o build/uart.o -lgcc
sram_image aefft_test
${PFX}size bin/aefft_test.elf
