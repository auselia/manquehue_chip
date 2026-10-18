#!/bin/bash
# Build programs that run from the QSPI flash (link_flash.ld, crt0_flash.S, uart library of hello_world).
# usage: ./build.sh [prog.c ...]   default: flash_hello.c
#   -> bin/<prog>.elf, bin/<prog>.dump, bin/<prog>.flash.hex (objcopy -O verilog, addresses relative to
#      0x2000_0000, for the flash model: scripts/sim/run_verilator.sh with FLASH=bin/<prog>.flash.hex)
#   RISCV_PREFIX (default riscv32-none-elf-), MARCH (default rv32i_zicsr), EXTRA (more sources, for example
#   ../aefft_bench/mulsi3.S), NAME (output name, one program only), DEFS (compiler defines)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
HW=../hello_world
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
FLAGS="-march=${MARCH:-rv32i_zicsr} -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
PROGS=${*:-flash_hello.c}
mkdir -p build bin
${PFX}gcc $FLAGS -c crt0_flash.S -o build/crt0_flash.o
${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $HW/lib/src/uart.c -o build/uart.o
extra_objs=""
for e in ${EXTRA:-}; do
  ${PFX}gcc $FLAGS -c $e -o build/$(basename ${e%.*}).o
  extra_objs="$extra_objs build/$(basename ${e%.*}).o"
done
for src in $PROGS; do
  t=${NAME:-$(basename ${src%.*})}     # NAME= names the output when building one program
  ${PFX}gcc $FLAGS ${DEFS:-} -I$HW/lib/inc -I$HW -I$(dirname $src) -c $src -o build/$t.o
  ${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -Tlink_flash.ld -o bin/$t.elf \
    build/crt0_flash.o build/$t.o build/uart.o $extra_objs
  ${PFX}objdump -D -s bin/$t.elf > bin/$t.dump
  ${PFX}objcopy -O verilog --change-addresses -0x20000000 bin/$t.elf bin/$t.flash.hex
  ${PFX}size -A bin/$t.elf | awk -v t=$t '$1 ~ /^\./ && $2 > 0 {printf "%s %-14s %6d bytes at 0x%08x\n", t, $1, $2, $3}'
done
