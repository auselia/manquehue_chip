#!/bin/bash
# Build one ZedBoard bring-up step (see README.md)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh <step> [more compiler options]      (env: DEFS, for example -DFRF=0xD90000u (868 MHz),
#        -DNPKT=100, -DCLK_HZ=20000u (simulation: 1000 times shorter waits))
# in:  the step sources, ../flash/crt0_flash.S and link_flash.ld for the flash steps
# out: SRAM steps (s0_hello s1_fft s2_qspi s2b_flasher s9_adc_reset): bin/<step>.{elf,dump,hex}
#      flash steps (s3_adc s4_lora s4_sx1262 s5_adc_fft s6_adc_fft_lora s7_event s8_event_lora): bin/<step>.{elf,dump},
#      bin/<step>.flash.{bin,hex} and bin/<step>.psram.{bin,hex} (the flasher copies the PSRAM image into the flash)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
step=$1
shift || true
. ../lib/firmware.sh
use_soft_float_gcc
set_march rv32ic_zicsr
flash=../flash

runs_from_flash=0
case $step in
  s0_hello | s1_fft | s2b_flasher | s9_adc_reset) source_file=$step.c ;;
  s2_qspi)          source_file=../qspi_cmd/qspi_cmd_test.c ;;
  s3_adc | s4_lora | s7_event | s4_sx1262) source_file=$step.c; runs_from_flash=1 ;;
  s8_event_lora)    source_file=s7_event.c;    runs_from_flash=1; set -- -DLORA "$@" ;;
  s5_adc_fft)       source_file=s56_adc_fft.c; runs_from_flash=1 ;;
  s6_adc_fft_lora)  source_file=s56_adc_fft.c; runs_from_flash=1; set -- -DLORA "$@" ;;
  *) echo "usage: $0 <step>"; exit 1 ;;
esac
compile "$LIB/src/uart.c"

if [ $runs_from_flash = 1 ]; then
  compile "$flash/crt0_flash.S"
  # shellcheck disable=SC2086  # DEFS is a list of options
  compile "$source_file" "$step" -- -DXIP ${DEFS:-} "$@" -I.
  link "$step" "$flash/link_flash.ld" build/crt0_flash.o "build/$step.o" build/uart.o
  flash_images "$step"
  psram_images "$step"
  ${PFX}size -A "bin/$step.elf" | awk '$1 ~ /^\./ && $2 > 0 {printf "  %-14s %6d bytes at 0x%08x\n", $1, $2, $3}'
  echo "ok: $step, flash image $(stat -c %s "bin/$step.flash.bin") bytes"
  exit 0
fi

compile "$LIB/crt0.S"
# shellcheck disable=SC2086
compile "$source_file" "$step" -- ${DEFS:-} "$@" -I.
link "$step" ../gls_mini/link.ld build/crt0.o "build/$step.o" build/uart.o -lgcc
sram_image "$step"
${PFX}size "bin/$step.elf"
# Code and data end below the sample buffer (BUF0 in bringup.h) in steps 0 and 1, below the cookie word at
# 0x1000063C in step 9, and below the stack (top 192 B) in the others
case $step in
  s1_fft)       check_end "$step" 0x10000640 "the sample buffer" ;;
  s9_adc_reset) check_end "$step" 0x10000638 "the cookie word" ;;
  *)            check_end "$step" 0x10000740 "the stack" ;;
esac
