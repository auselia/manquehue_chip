#!/bin/bash
# Build the SPI block tests for the 2 KB SRAM: spi_regs (registers from the CPU) and spi_adc (ADC capture into the
# SRAM, with the ADS7057 model of sim/tb/tb_croc_soc.sv)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh
# in:  spi_regs.c, spi_adc.c, the linker script of gls_mini
# out: bin/<test>.{elf,dump,hex}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
set_march rv32i_zicsr

compile "$LIB/crt0.S"
compile "$LIB/src/uart.c"
for program in spi_regs spi_adc; do
  compile "$program.c"
  link "$program" ../gls_mini/link.ld build/crt0.o "build/$program.o" build/uart.o -lgcc
  sram_image "$program"
  ${PFX}size "bin/$program.elf" | tail -1
done
