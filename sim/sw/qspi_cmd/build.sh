#!/bin/bash
# Build the QSPI command engine test for the 2 KB SRAM (RTL simulation, or over JTAG on the ZedBoard).
# Compressed instructions (rv32ic): with rv32i the code (about 2 KB) does not fit next to the 256 B sample buffer
# and the stack. The CVE2 core always has the C extension.
# usage: ./build.sh   -> bin/qspi_cmd_test.{elf,hex,dump}
#        RISCV_PREFIX   default riscv32-none-elf-
#        DEFS           for example -DFRF=0xD90000u (868 MHz), -DNPKT=100, or "-DCLK_HZ=20000u -DNPKT=2" (simulation)
#        NAME           output name (default fft_lora)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
HW=../hello_world
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
# the soft-float rv32 toolchain (the gcc 16 of the nix profile has a double-float libgcc)
NOLIBC=$(ls -d /nix/store/*-riscv32-none-elf-nolibc-gcc-15*/bin 2>/dev/null | head -1)
[ -n "$NOLIBC" ] && export PATH=$NOLIBC:$PATH
T=${NAME:-qspi_cmd_test}
FLAGS="-march=rv32ic_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
for f in $HW/crt0.S $HW/lib/src/uart.c; do
  ${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $f -o build/$(basename ${f%.*}).o
done
${PFX}gcc $FLAGS ${DEFS:-} -I$HW/lib/inc -I$HW -c qspi_cmd_test.c -o build/$T.o
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T../gls_mini/link.ld -o bin/$T.elf build/crt0.o build/$T.o build/uart.o -lgcc
${PFX}objdump -D -s bin/$T.elf > bin/$T.dump
${PFX}objcopy -O verilog bin/$T.elf bin/$T.hex
# the code and its data must leave room for the stack (256 B) at the top of the 2 KB SRAM
END=$(${PFX}nm -n -S bin/$T.elf | awk '$3 ~ /^[tTdDbBrR]$/ {e = strtonum("0x" $1) + strtonum("0x" $2)} END {printf "%08x", e}')
${PFX}size bin/$T.elf
[ $((16#$END)) -gt $((16#10000700)) ] && { echo "ERROR: code and data end at 0x$END, above 0x10000700"; exit 1; }
echo "ok: $T, code and data end at 0x$END"
