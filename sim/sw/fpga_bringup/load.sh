#!/bin/bash
# Load a bring-up step over the J-Link (Pmod JA), on the Mac. Copy bin/ from Rocky into this folder first.
#   ./load.sh <step>    s0_hello s1_fft s2_qspi: into the SRAM and run
#                       s3_adc s4_lora s5_adc_fft s6_adc_fft_lora s7_event: image into PSRAM A, the flasher writes it into the
#                       flash ("FLASH WRITE OK" on the UART), then croc resets and boots it from the flash
#   ./load.sh boot      reset croc, it boots what the flash holds (the same as BTNC)
# ra = 0x02000100 (bootrom _eoc, as the bootrom sets it): main returns there and stops, instead of to the stale ra.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
S=${1:?step}
case $S in
  s0_hello|s1_fft|s2_qspi)
    openocd -f openocd-croc.cfg -c "load_image bin/$S.elf; verify_image bin/$S.elf; reg pc 0x1000000c; reg ra 0x02000100; resume; shutdown" ;;
  s3_adc|s4_lora|s5_adc_fft|s6_adc_fft_lora|s7_event)
    openocd -f openocd-croc.cfg -c "load_image bin/$S.psram.bin 0x21000000 bin; verify_image bin/$S.psram.bin 0x21000000 bin; load_image bin/s2b_flasher.elf; verify_image bin/s2b_flasher.elf; reg pc 0x1000000c; reg ra 0x02000100; resume; sleep 5000; reset run; shutdown" ;;
  boot)
    openocd -f openocd-croc.cfg -c "reset run; shutdown" ;;
  *) echo "usage: $0 <step>|boot"; exit 1 ;;
esac
