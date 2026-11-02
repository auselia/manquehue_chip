#!/bin/bash
# Build the ZedBoard FFT + LoRa demo for the 2 KB SRAM, loaded over JTAG (openocd-croc.cfg, see README.md).
# Compressed instructions (rv32ic): with rv32i the code (about 2 KB) does not fit next to the 256 B sample buffer
# and the stack. The CVE2 core always has the C extension.
# usage: ./build.sh   -> bin/fft_lora.{elf,hex,dump}
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
T=${NAME:-fft_lora}
FLAGS="-march=rv32ic_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
for f in $HW/crt0.S $HW/lib/src/uart.c; do
  ${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $f -o build/$(basename ${f%.*}).o
done
${PFX}gcc $FLAGS ${DEFS:-} -I$HW/lib/inc -I$HW -c fft_lora.c -o build/$T.o
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T../gls_mini/link.ld -o bin/$T.elf build/crt0.o build/$T.o build/uart.o -lgcc
${PFX}objdump -D -s bin/$T.elf > bin/$T.dump
${PFX}objcopy -O verilog bin/$T.elf bin/$T.hex
# the code and its data must end below the sample buffer (BUF in fft_lora.c)
BUF=$(sed -n 's/^#define BUF \(0x[0-9a-fA-F]*\)u.*/\1/p' fft_lora.c)
END=$(${PFX}nm -n -S bin/$T.elf | awk '$3 ~ /^[tTdDbBrR]$/ {e = strtonum("0x" $1) + strtonum("0x" $2)} END {printf "%08x", e}')
${PFX}size bin/$T.elf
[ $((16#$END)) -gt $(($BUF)) ] && { echo "ERROR: code and data end at 0x$END, above the sample buffer at $BUF"; exit 1; }
echo "ok: $T, code and data end at 0x$END, sample buffer at $BUF"
