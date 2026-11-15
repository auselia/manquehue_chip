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
export PATH=${VERILATOR_BIN:-/nix/store/i5hjqqy2qk6jac8mnnaxnlh8yfi49wjh-verilator-5.052/bin}:$PATH
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
check fft_block "^PASS" bash sim/fft/run_bus.sh
check models    "^PASS: models self-test" bash sim/models/run_models.sh "$OUT/models"
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
