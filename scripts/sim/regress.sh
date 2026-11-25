#!/bin/bash
# RTL regression: the block test benches and the bring-up regression, with one summary
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/sim/regress.sh      (env: OUT, default sim/build/regress; BRINGUP=0 skips the bring-up regression)
# in:  rtl/, sim/tb/, sim/fft/, sim/models/, sim/sw/ (needs Verilator 5, iverilog and riscv32-none-elf-gcc)
# out: $OUT/summary.txt ("<test>: PASS|FAIL" lines, the last one "status: PASS|FAIL") and one log per test
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$REPO/scripts/utils/env.sh"
OUT=${OUT:-$REPO/sim/build/regress}
mkdir -p "$OUT"; S=$OUT/summary.txt; : > "$S"
export PATH=$VERILATOR_BIN:$PATH
ST=PASS

# check <name> <pass pattern> <command...>: PASS when the log has the pattern and no FAIL line
check() {
  local name=$1 pass=$2; shift 2
  "$@" > "$OUT/$name.log" 2>&1
  if grep -qE "$pass" "$OUT/$name.log" && ! grep -qE "^(\[[A-Z0-9 ]+\] )?FAIL|: FAIL$| FAIL$" "$OUT/$name.log"; then
    echo "$name: PASS" >> "$S"
  else
    echo "$name: FAIL (see $OUT/$name.log)" >> "$S"; ST=FAIL
  fi
}

cd "$REPO" || exit 1
check spi_block "^PASS" bash scripts/sim/run_obi_spi_tb.sh "$OUT/spi_block"
# the FFT bus test at response latencies 1 to 3, with and without random grant
check fft_block "^PASS" bash sim/fft/run_all.sh
check models    "^PASS: models self-test" bash sim/models/run_models.sh "$OUT/models"
# the I2C host against sim/models/i2c_target_model.v: write, register read, NACK, at 100 and 400 kHz
check i2c       "Simulation finished: SUCCESS" make sim BIN=sim/sw/i2c_test/bin/i2c_test.hex
if [ "${BRINGUP:-1}" != 0 ]; then
  # the bring-up steps of the ZedBoard in the RTL test bench: every step line says OK
  OUT=$OUT/bringup bash scripts/sim/run_bringup_sim.sh > "$OUT/bringup.log" 2>&1
  B=$OUT/bringup/summary.txt
  # a failed step says FAIL or "no result"
  if [ -f "$B" ] && grep -q "^DONE" "$B" && ! grep -q "FAIL" "$B" && ! grep -E "^[a-z0-9_]+: " "$B" | grep -qv " OK"; then
    echo "bringup: PASS ($(grep -cE "^[a-z0-9_]+: " "$B") steps OK)" >> "$S"
  else
    echo "bringup: FAIL (see $B)" >> "$S"; ST=FAIL
  fi
fi
echo "status: $ST" >> "$S"
cat "$S"
[ "$ST" = PASS ]
