#!/bin/bash
# Build the AE-FFT system test for the 2 KB SRAM.  usage: ./build.sh  -> bin/aefft_test.{elf,hex,dump}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
HW=../hello_world
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
FLAGS="-march=rv32i_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
python3 ../../fft/gen_fw_header.py
for f in $HW/crt0.S main.c $HW/lib/src/uart.c; do
  ${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $f -o build/$(basename ${f%.*}).o
done
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -Tlink.ld -o bin/aefft_test.elf build/crt0.o build/main.o build/uart.o -lgcc
${PFX}objdump -D -s bin/aefft_test.elf > bin/aefft_test.dump
${PFX}objcopy -O verilog bin/aefft_test.elf bin/aefft_test.hex
${PFX}size bin/aefft_test.elf
