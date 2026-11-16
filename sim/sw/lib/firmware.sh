# Build helpers that every build.sh of sim/sw shares: compile, link, images for the flash and the PSRAM, end check
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: . ../lib/firmware.sh in a build.sh (it runs in its program folder), then set_march and the functions
# in:  env RISCV_PREFIX (default riscv32-none-elf-)
# out: build/<name>.o, bin/<name>.{elf,dump,hex} and the flash and PSRAM images
# shellcheck shell=bash

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PFX=${RISCV_PREFIX:-riscv32-none-elf-}
FLAGS_COMMON="-mabi=ilp32 -mcmodel=medany -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding -ffunction-sections -fdata-sections"
mkdir -p build bin

# set_march <march>: the compile flags for rv32i_zicsr or rv32ic_zicsr (FLAGS)
set_march() {
  FLAGS="-march=$1 $FLAGS_COMMON"
}

# use_soft_float_gcc: put the soft-float gcc 15 first on PATH (the gcc 16 of the nix profile has a double-float
# libgcc, which a program that needs -lgcc cannot link)
use_soft_float_gcc() {
  local nolibc
  nolibc=$(ls -d /nix/store/*-riscv32-none-elf-nolibc-gcc-15*/bin 2>/dev/null | head -1)
  [ -n "$nolibc" ] && export PATH=$nolibc:$PATH
  return 0
}

# compile <source> [<object name>] [-- <gcc options>]: build/<object name>.o (default: the source name)
compile() {
  local source=$1 name
  name=$(basename "${source%.*}")
  shift
  if [ $# -gt 0 ] && [ "$1" != -- ]; then name=$1; shift; fi
  [ "${1:-}" = -- ] && shift
  # shellcheck disable=SC2086  # FLAGS is a list of options
  ${PFX}gcc $FLAGS "$@" -I"$LIB/inc" -I"$LIB" -c "$source" -o "build/$name.o"
}

# link <program> <linker script> <objects...>: bin/<program>.elf and its disassembly
link() {
  local program=$1 script=$2
  shift 2
  # shellcheck disable=SC2086
  ${PFX}gcc $FLAGS -nostartfiles -Wl,--gc-sections -T"$script" -o "bin/$program.elf" "$@"
  ${PFX}objdump -D -s "bin/$program.elf" > "bin/$program.dump"
}

# sram_image <program>: bin/<program>.hex, for the JTAG load into the SRAM
sram_image() {
  ${PFX}objcopy -O verilog "bin/$1.elf" "bin/$1.hex"
}

# flash_images <program>: bin/<program>.flash.hex (addresses from 0x2000_0000 on, for the flash model) and
# bin/<program>.flash.bin (from flash offset 0, for a flash programmer)
flash_images() {
  ${PFX}objcopy -O verilog --change-addresses -0x20000000 "bin/$1.elf" "bin/$1.flash.hex"
  ${PFX}objcopy -O binary "bin/$1.elf" "bin/$1.flash.bin"
}

# psram_images <program>: bin/<program>.psram.{bin,hex}, the flash image with its length, for PSRAM A
psram_images() {
  python3 "$LIB/psram_image.py" "bin/$1.flash.bin" "bin/$1.psram.bin" "bin/$1.psram.hex"
}

# image_end <program>: the end address of code and data (hex digits), from the symbol table
image_end() {
  ${PFX}nm -n -S "bin/$1.elf" | awk '$3 ~ /^[tTdDbBrR]$/ {e = strtonum("0x" $1) + strtonum("0x" $2)} END {printf "%08x", e}'
}

# check_end <program> <limit> <what is at the limit>: stop when code and data end above the limit
check_end() {
  local program=$1 limit=$2 what=$3 end
  end=$(image_end "$program")
  if [ $((16#$end)) -gt $((limit)) ]; then
    echo "ERROR: $program ends at 0x$end, above $limit ($what)"
    exit 1
  fi
  echo "ok: $program ends at 0x$end, $what at $limit"
}
