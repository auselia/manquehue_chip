#!/bin/bash
# RTL simulation of the ZedBoard bring-up steps (sim/sw/fpga_bringup) in the SoC test bench
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/sim/run_bringup_sim.sh      (env: OUT, default sim/build/bringup_sim; VERILATOR_BIN)
# in:  sim/sw/fpga_bringup, the SoC test bench with the ADC, flash, PSRAM and radio models
# out: $OUT/summary.txt (one line per step, OK or FAIL, then DONE), one log per step, build.log
#
# Steps 0 to 2 run from the SRAM over JTAG. Steps 3 to 8 take the whole board path: the flasher (JTAG, SRAM) copies
# the step image from PSRAM A (preloaded, as OpenOCD does on the board) into the flash and jumps to it (-DBOOT, the
# bootrom does that after BTNC). Steps 4 and 8 also run with the SX1262 model, at 1 MHz and at the board's 50 kHz.
. "$(dirname "${BASH_SOURCE[0]}")/../utils/env.sh"
cd "$REPO" || exit 1
export PATH=$VERILATOR_BIN:$PATH
out=${OUT:-$REPO/sim/build/bringup_sim}
rm -rf "$out"
mkdir -p "$out"
summary_file=$out/summary.txt
echo "started $(date "+%F %T"), $(git log -1 --format=%h) plus uncommitted edits" > "$summary_file"
steps_dir=sim/sw/fpga_bringup
images=$REPO/$steps_dir/bin
# simulation builds: 1000 times shorter waits, 2 packets, 2 blocks
short="-DCLK_HZ=20000u -DTIMEOUT=2000000u -DNPKT=2 -DNBLK=2"

# build_steps <step and options>...: build every step, each argument is one build.sh call
build_steps() {
  local call
  for call in "$@"; do
    # shellcheck disable=SC2086  # each call is a step name and its options
    ( cd "$steps_dir" && ./build.sh $call ) >> "$out/build.log" 2>&1 || return 1
  done
}

# simulate <name> <program.hex> <plusargs> <result pattern>: one simulation, its result line goes to the summary
simulate() {
  local name=$1 program=$2 plusargs=$3 pattern=$4 start result
  start=$(date +%s)
  SIM_ARGS="$plusargs" timeout 3600 bash scripts/sim/run_verilator.sh "$program" > "$out/$name.sim.log" 2>&1 < /dev/null
  result=$(grep -aE "$pattern" "$out/$name.sim.log" | grep -aE " OK| FAIL" | tail -1)
  echo "$name: ${result:-no result} ($(( $(date +%s) - start )) s)" >> "$summary_file"
}

# flash_step <name> <step> <plusargs>: the flasher writes the step into the flash, then the step runs from there
flash_step() {
  local name=$1 step=$2
  local plusargs="+psram0=$images/$step.psram.hex $3"
  simulate "$name" "$images/s2b_flasher.hex" "$plusargs" "STEP[3-8]"
  echo "  $(grep -aE "FLASH WRITE" "$out/$name.sim.log" | grep -aE "OK|FAIL" | tail -1 | sed "s/.*UART\] //")" >> "$summary_file"
  grep -a "^\[SX1262\] summary" "$out/$name.sim.log" | sed "s/^/  /" >> "$summary_file"
}

if ! build_steps "s0_hello $short -DNO_GPIO_READBACK" "s1_fft $short" "s2_qspi" "s2b_flasher -DBOOT" \
    "s3_adc $short -DRAMP" "s4_lora $short" "s5_adc_fft $short -DEXPECT_BIN=36" "s6_adc_fft_lora $short -DEXPECT_BIN=36" \
    "s4_sx1262 $short -DSX_CLKDIV=9u" "s8_event_lora $short -DNEV=1 -DSX_CLKDIV=9u"; then
  echo "build FAIL" >> "$summary_file"
  echo DONE >> "$summary_file"
  exit 1
fi
simulate s0_hello "$images/s0_hello.hex" "" "STEP0"
simulate s1_fft "$images/s1_fft.hex" "" "STEP1"
simulate s2_qspi "$images/s2_qspi.hex" "" "QSPI CMD"
# The SX1262 steps at an SCLK of 1 MHz (SX_CLKDIV 9). s8: one event, WAKE_N at ADC frame 3000.
flash_step s3_adc s3_adc ""
flash_step s4_lora s4_lora "+adc_tone=36"
flash_step s5_adc_fft s5_adc_fft "+adc_tone=36"
flash_step s6_adc_fft_lora s6_adc_fft_lora "+adc_tone=36"
flash_step s4_sx1262 s4_sx1262 "+adc_tone=36 +rf=sx1262"
flash_step s8_event_lora s8_event_lora "+adc_tone=36 +rf=sx1262 +adc_wake_frame=3000"

# The same two steps at the board SCLK of 50 kHz (SX_CLKDIV 199, the default of sx1262.h), the rate of the Heltec bridge
if ! build_steps "s4_sx1262 $short" "s8_event_lora $short -DNEV=1"; then
  echo "build 50 kHz FAIL" >> "$summary_file"
  echo DONE >> "$summary_file"
  exit 1
fi
flash_step s4_sx1262_50k s4_sx1262 "+adc_tone=36 +rf=sx1262"
flash_step s8_event_lora_50k s8_event_lora "+adc_tone=36 +rf=sx1262 +adc_wake_frame=3000"
echo DONE >> "$summary_file"
