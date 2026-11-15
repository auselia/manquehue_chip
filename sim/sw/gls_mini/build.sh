#!/bin/bash
# Build the 2 KB bring-up program (prints "GLS OK" on the UART) for the current SRAM size.
# lib/link.ld (of hello_world and the other Makefile programs) still assumes the old 16 KB SRAM; this one links
# into 2 KB (link.ld LENGTH 2K, gc-sections, only uart.c from the library).
# usage: ./build.sh   -> bin/gls_mini.{elf,hex,dump}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
LIB=../lib
PFX=${RISCV_PREFIX:-riscv64-unknown-elf-}
FLAGS="-march=rv32i_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
for f in $LIB/crt0.S gls_mini.c $LIB/src/uart.c; do
  ${PFX}gcc $FLAGS -I$LIB/inc -I$LIB -c $f -o build/$(basename ${f%.*}).o
done
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -Tlink.ld -o bin/gls_mini.elf build/crt0.o build/gls_mini.o build/uart.o -lgcc
${PFX}objdump -D -s bin/gls_mini.elf > bin/gls_mini.dump
${PFX}objcopy -O verilog bin/gls_mini.elf bin/gls_mini.hex
${PFX}size bin/gls_mini.elf
