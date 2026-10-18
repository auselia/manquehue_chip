#!/bin/bash
# Build the register test of the SPI block for the 2 KB SRAM (link script and library of gls_mini and hello_world).
# usage: ./build.sh   -> bin/spi_regs.{elf,hex,dump}
#        RISCV_PREFIX   default riscv32-none-elf- (nix toolchain on Rocky)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
HW=../hello_world
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
FLAGS="-march=rv32i_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
for f in $HW/crt0.S spi_regs.c $HW/lib/src/uart.c; do
  ${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $f -o build/$(basename ${f%.*}).o
done
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T../gls_mini/link.ld -o bin/spi_regs.elf build/crt0.o build/spi_regs.o build/uart.o -lgcc
${PFX}objdump -D -s bin/spi_regs.elf > bin/spi_regs.dump
${PFX}objcopy -O verilog bin/spi_regs.elf bin/spi_regs.hex
${PFX}size bin/spi_regs.elf
