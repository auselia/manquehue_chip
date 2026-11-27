#!/bin/bash
# Build i2c_test, the 2 KB I2C host test: it runs against sim/models/i2c_target_model.v in tb_croc_soc
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ./build.sh
# in:  i2c_test.c, ../gls_mini/link.ld (LENGTH 2K, the real SRAM)
# out: bin/i2c_test.{elf,dump,hex}
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/firmware.sh
set_march rv32i_zicsr

for source in "$LIB/crt0.S" i2c_test.c; do compile "$source"; done
link i2c_test ../gls_mini/link.ld build/crt0.o build/i2c_test.o -lgcc
sram_image i2c_test
${PFX}size bin/i2c_test.elf
