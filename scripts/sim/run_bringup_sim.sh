#!/bin/bash
# RTL simulation of the ZedBoard bring-up steps (sim/sw/fpga_bringup). Steps 0 to 2 from the SRAM over JTAG. Steps
# 3 to 6 through the whole board path: the flasher (JTAG, SRAM) copies the step image from PSRAM A (preloaded, as
# OpenOCD does on the board) into the flash, then jumps to it (-DBOOT, the bootrom does that after BTNC). Steps 4
# and 8 also with the SX1262 model (sim/models/sx1262_model.v), as on the ZedBoard.
# usage: scripts/sim/run_bringup_sim.sh      (env: OUT, results folder, default sim/build/bringup_sim;
#                                             VERILATOR_BIN, a Verilator 5 with --timing; needs riscv32 gcc)
# Result: $OUT/summary.txt, one line per step (OK or FAIL), and one log per step.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO" || exit 1
VERILATOR_BIN=${VERILATOR_BIN:-/nix/store/i5hjqqy2qk6jac8mnnaxnlh8yfi49wjh-verilator-5.052/bin}
export PATH=$VERILATOR_BIN:$PATH
L=${OUT:-$REPO/sim/build/bringup_sim}; rm -rf $L; mkdir -p $L; S=$L/summary.txt
echo "started $(date "+%F %T"), $(git log -1 --format=%h) plus uncommitted edits" > $S
B=sim/sw/fpga_bringup; P=$(pwd)/$B/bin
SHORT="-DCLK_HZ=20000u -DTIMEOUT=2000000u -DNPKT=2 -DNBLK=2"
sim() { name=$1; hex=$2; args=$3; pat=$4
  t0=$(date +%s)
  SIM_ARGS="$args" timeout 3600 bash scripts/sim/run_verilator.sh $hex > $L/$name.sim.log 2>&1 </dev/null
  r=$(grep -aE "$pat" $L/$name.sim.log | grep -aE " OK| FAIL" | tail -1)
  echo "$name: ${r:-no result} ($(( $(date +%s) - t0 )) s)" >> $S
}
( cd $B && ./build.sh s0_hello $SHORT -DNO_GPIO_READBACK && ./build.sh s1_fft $SHORT && ./build.sh s2_qspi \
  && ./build.sh s2b_flasher -DBOOT && ./build.sh s3_adc $SHORT -DRAMP && ./build.sh s4_lora $SHORT \
  && ./build.sh s5_adc_fft $SHORT -DEXPECT_BIN=36 && ./build.sh s6_adc_fft_lora $SHORT -DEXPECT_BIN=36 \
  && ./build.sh s4_sx1262 $SHORT -DSX_CLKDIV=9u && ./build.sh s8_event_lora $SHORT -DNEV=1 -DSX_CLKDIV=9u ) > $L/build.log 2>&1 \
  || { echo "build FAIL" >> $S; echo DONE >> $S; exit 1; }
sim s0_hello $P/s0_hello.hex "" "STEP0"
sim s1_fft   $P/s1_fft.hex   "" "STEP1"
sim s2_qspi  $P/s2_qspi.hex  "" "QSPI CMD"
# s4_sx1262 and s8_event_lora: SX1262 model (+rf=sx1262, BUSY on DIO0), SCLK 1 MHz (SX_CLKDIV 9, the board uses 50 kHz
# through the Heltec bridge). s8: one event, WAKE_N at ADC frame 3000.
for s in s3_adc s4_lora s5_adc_fft s6_adc_fft_lora s4_sx1262 s8_event_lora; do
  A="+psram0=$P/$s.psram.hex"; [ $s = s3_adc ] || A="$A +adc_tone=36"
  case $s in s4_sx1262) A="$A +rf=sx1262" ;; s8_event_lora) A="$A +rf=sx1262 +adc_wake_frame=3000" ;; esac
  sim $s $P/s2b_flasher.hex "$A" "STEP[3-8]"
  echo "  $(grep -aE "FLASH WRITE" $L/$s.sim.log | grep -aE "OK|FAIL" | tail -1 | sed "s/.*UART\] //")" >> $S
  grep -a "^\[SX1262\] summary" $L/$s.sim.log | sed "s/^/  /" >> $S
done
echo DONE >> $S
