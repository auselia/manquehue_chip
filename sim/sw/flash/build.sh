#!/bin/bash
# Build programs that run from the QSPI flash (crt0_flash.S, link_flash.ld)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh [program.c ...]      (default flash_hello.c; env: MARCH (default rv32i_zicsr), DEFS,
#        EXTRA (more sources, for example ../aefft_bench/mulsi3.S), NAME (the output name, one program only))
# in:  the program sources
# out: bin/<program>.{elf,dump}, bin/<program>.flash.hex (for the flash model: run_verilator.sh with FLASH=...),
#      bin/<program>.flash.bin (for a flash programmer)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
set_march "${MARCH:-rv32i_zicsr}"
programs=${*:-flash_hello.c}

compile crt0_flash.S
compile "$LIB/src/uart.c"
extra_objects=""
for source in ${EXTRA:-}; do
  compile "$source"
  extra_objects="$extra_objects build/$(basename "${source%.*}").o"
done
for source in $programs; do
  program=${NAME:-$(basename "${source%.*}")}
  # shellcheck disable=SC2086  # DEFS is a list of options
  compile "$source" "$program" -- ${DEFS:-} -I"$(dirname "$source")"
  # shellcheck disable=SC2086
  link "$program" link_flash.ld build/crt0_flash.o "build/$program.o" build/uart.o $extra_objects
  flash_images "$program"
  ${PFX}size -A "bin/$program.elf" | awk -v t="$program" '$1 ~ /^\./ && $2 > 0 {printf "%s %-14s %6d bytes at 0x%08x\n", t, $1, $2, $3}'
done
