#!/bin/bash
# Build one ZedBoard bring-up step (see README.md).
# usage: ./build.sh <step> [more DEFS]
#   from the SRAM (loaded over JTAG):  s0_hello s1_fft s2_qspi s2b_flasher        -> bin/<step>.{elf,hex,dump}
#   from the QSPI flash (XIP):         s3_adc s4_lora s5_adc_fft s6_adc_fft_lora  -> bin/<step>.{elf,dump},
#        bin/<step>.flash.{bin,hex} (flash image, hex relative to 0x2000_0000 for the flash model) and
#        bin/<step>.psram.{bin,hex} (length word + image, for PSRAM A: the flasher copies it into the flash)
#   DEFS   for example -DFRF=0xD90000u (868 MHz), -DNPKT=100, -DCLK_HZ=20000u (simulation: 1000 times shorter waits)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
STEP=$1; shift || true
HW=../hello_world
FL=../flash
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
NOLIBC=$(ls -d /nix/store/*-riscv32-none-elf-nolibc-gcc-15*/bin 2>/dev/null | head -1)
[ -n "$NOLIBC" ] && export PATH=$NOLIBC:$PATH
XIP=0
case $STEP in
  s0_hello|s1_fft|s2b_flasher|s9_adc_reset) SRC=$STEP.c ;;
  s2_qspi)          SRC=../qspi_cmd/qspi_cmd_test.c ;;
  s3_adc|s4_lora|s7_event|s4_sx1262) SRC=$STEP.c; XIP=1 ;;
  s8_event_lora)    SRC=s7_event.c; XIP=1; set -- -DLORA "$@" ;;
  s5_adc_fft)       SRC=s56_adc_fft.c; XIP=1 ;;
  s6_adc_fft_lora)  SRC=s56_adc_fft.c; XIP=1; set -- -DLORA "$@" ;;
  *) echo "usage: $0 <step>"; exit 1 ;;
esac
FLAGS="-march=rv32ic_zicsr -mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin
${PFX}gcc $FLAGS -I$HW/lib/inc -I$HW -c $HW/lib/src/uart.c -o build/uart.o
if [ $XIP = 1 ]; then
  ${PFX}gcc $FLAGS -c $FL/crt0_flash.S -o build/crt0_flash.o
  ${PFX}gcc $FLAGS -DXIP ${DEFS:-} "$@" -I. -I$HW/lib/inc -I$HW -c $SRC -o build/$STEP.o
  ${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T$FL/link_flash.ld -o bin/$STEP.elf build/crt0_flash.o build/$STEP.o build/uart.o
  ${PFX}objdump -D -s bin/$STEP.elf > bin/$STEP.dump
  ${PFX}objcopy -O verilog --change-addresses -0x20000000 bin/$STEP.elf bin/$STEP.flash.hex
  ${PFX}objcopy -O binary bin/$STEP.elf bin/$STEP.flash.bin
  python3 - bin/$STEP.flash.bin bin/$STEP.psram.bin <<'PY'
import struct, sys
img = open(sys.argv[1], 'rb').read()
img += b'\0' * (-len(img) % 4)
open(sys.argv[2], 'wb').write(struct.pack('<I', len(img)) + img)
PY
  # for the PSRAM model (simulation): croc stores words in the PSRAM most significant byte first, and the model is
  # preloaded around croc. On the board OpenOCD writes through croc itself, so it takes the .psram.bin as it is.
  python3 - bin/$STEP.psram.bin bin/$STEP.psram.hex <<PY
import sys
d = open(sys.argv[1], "rb").read()
w = b"".join(d[i:i + 4][::-1] for i in range(0, len(d), 4))
open(sys.argv[2], "w").write("@00000000\n" + "\n".join(" ".join("%02X" % b for b in w[i:i + 16]) for i in range(0, len(w), 16)) + "\n")
PY
  ${PFX}size -A bin/$STEP.elf | awk '$1 ~ /^\./ && $2 > 0 {printf "  %-14s %6d bytes at 0x%08x\n", $1, $2, $3}'
  echo "ok: $STEP, flash image $(stat -c %s bin/$STEP.flash.bin) bytes"
  exit 0
fi
${PFX}gcc $FLAGS -c $HW/crt0.S -o build/crt0.o
${PFX}gcc $FLAGS ${DEFS:-} "$@" -I. -I$HW/lib/inc -I$HW -c $SRC -o build/$STEP.o
${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T../gls_mini/link.ld -o bin/$STEP.elf build/crt0.o build/$STEP.o build/uart.o -lgcc
${PFX}objdump -D -s bin/$STEP.elf > bin/$STEP.dump
${PFX}objcopy -O verilog bin/$STEP.elf bin/$STEP.hex
# code and data must end below the sample buffer (BUF0 in bringup.h, steps 0 and 1), below the stack (top 192 B)
# for the others
LIMIT=0x10000740
[ $STEP = s1_fft ] && LIMIT=0x10000640
[ $STEP = s9_adc_reset ] && LIMIT=0x10000638              # the cookie word at 0x1000063C
END=$(${PFX}nm -n -S bin/$STEP.elf | awk '$3 ~ /^[tTdDbBrR]$/ {e = strtonum("0x" $1) + strtonum("0x" $2)} END {printf "%08x", e}')
${PFX}size bin/$STEP.elf
[ $((16#$END)) -gt $(($LIMIT)) ] && { echo "ERROR: $STEP ends at 0x$END, above $LIMIT"; exit 1; }
echo "ok: $STEP ends at 0x$END (limit $LIMIT)"
