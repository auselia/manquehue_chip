#!/usr/bin/env python3
# The PSRAM image of a flash program: a length word, then the image (the flasher copies it from PSRAM A to the flash)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: psram_image.py <program.flash.bin> <out.psram.bin> <out.psram.hex>      (firmware.sh psram_images)
# in:  the flash image of objcopy -O binary
# out: the .bin for OpenOCD on the board, the .hex for the PSRAM model of the simulation
#
# croc stores words in the PSRAM most significant byte first, and the simulation preloads the model around croc, so
# the .hex has every word reversed. On the board OpenOCD writes through croc itself and takes the .bin as it is.
import struct
import sys

flash_bin, psram_bin, psram_hex = sys.argv[1:4]
with open(flash_bin, "rb") as f:
    image = f.read()
image += b"\0" * (-len(image) % 4)
with open(psram_bin, "wb") as f:
    f.write(struct.pack("<I", len(image)) + image)

with open(psram_bin, "rb") as f:
    data = f.read()
swapped = b"".join(data[i:i + 4][::-1] for i in range(0, len(data), 4))
lines = [" ".join("%02X" % byte for byte in swapped[i:i + 16]) for i in range(0, len(swapped), 16)]
with open(psram_hex, "w") as f:
    f.write("@00000000\n" + "\n".join(lines) + "\n")
