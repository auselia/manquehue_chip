#!/bin/bash
# Build the AE-FFT benchmark (accelerator against software) for the 2 KB SRAM.  usage: ./build.sh  -> bin/aefft_bench${TAG}.{elf,hex,dump}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
HW=../hello_world
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
FLAGS="-march=${MARCH:-rv32ic_zicsr} -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
TAG=${TAG:-}
DEFS=${DEFS:-}
mkdir -p build bin
# bench.h is committed. Regenerate it (needs numpy and the vectors) with REGEN=1 or when it is missing.
if [ -n "${REGEN:-}" ] || [ ! -f bench.h ]; then python3 gen_header.py; fi
for f in $HW/crt0.S main.c mulsi3.S $HW/lib/src/uart.c; do
  ${PFX}gcc $FLAGS $DEFS -I$HW/lib/inc -I$HW -c $f -o build/$(basename ${f%.*}).o
done
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -Tlink.ld -o bin/aefft_bench${TAG}.elf build/crt0.o build/main.o build/mulsi3.o build/uart.o
${PFX}objdump -D -s bin/aefft_bench${TAG}.elf > bin/aefft_bench${TAG}.dump
${PFX}objcopy -O verilog bin/aefft_bench${TAG}.elf bin/aefft_bench${TAG}.hex
${PFX}size bin/aefft_bench${TAG}.elf
