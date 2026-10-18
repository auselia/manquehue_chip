#!/bin/bash
# Build the SPI block tests for the 2 KB SRAM (link script of gls_mini, library of hello_world):
#   spi_regs  register test from the CPU
#   spi_adc   ADC capture into the SRAM (needs the ADS7057 model of rtl/test/tb_croc_soc.sv)
# usage: ./build.sh   -> bin/<test>.{elf,hex,dump}
#        RISCV_PREFIX   default riscv32-none-elf- (nix toolchain on Rocky)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
HW=../hello_world
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
FLAGS="-march=rv32i_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
for f in $HW/crt0.S $HW/lib/src/uart.c; do
  ${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $f -o build/$(basename ${f%.*}).o
done
for t in spi_regs spi_adc; do
  ${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $t.c -o build/$t.o
  ${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T../gls_mini/link.ld -o bin/$t.elf build/crt0.o build/$t.o build/uart.o -lgcc
  ${PFX}objdump -D -s bin/$t.elf > bin/$t.dump
  ${PFX}objcopy -O verilog bin/$t.elf bin/$t.hex
  ${PFX}size bin/$t.elf | tail -1
done
