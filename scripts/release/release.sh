#!/bin/bash
# The release files of a run: GDS, LEF, netlist, black box, the timing model of every corner, and their checksums
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/release/release.sh      (env: RUN; OUT, default <run>/release; RELEASE_FORCE=1 skips the check gate)
# in:  <run>/croc_soc.{gds,lef,v}, <run>/croc_soc_bb.v, <run>/etm/croc_soc_<corner>.lib, <run>/checks/*/summary.txt
# out: $OUT/: croc_soc.gds, .lef, .v, croc_soc_blackbox.v, croc_soc_<corner>.lib and sha256sums.txt
. "$(dirname "${BASH_SOURCE[0]}")/../utils/env.sh"
need "$RUN/$TOP.gds" RELEASE "no GDS in the run folder '$RUN'. Set RUN=<run>."
OUT=${OUT:-$RUN/release}

# Only a run that passed its checks is released
BAD=""
for c in signoff scan_sta gls dft; do
  st=$(sed -n 's/^status: //p' "$CHECKS_OUT/$c/summary.txt" 2>/dev/null | tail -1)
  [ "$st" = PASS ] || BAD="$BAD $c (${st:-not run})"
done
if [ -n "$BAD" ] && [ "${RELEASE_FORCE:-0}" != 1 ]; then
  echo "[RELEASE] ERROR: checks not PASS:$BAD. Run make signoff check RUN=..., or set RELEASE_FORCE=1."
  exit 1
fi
[ -z "$BAD" ] || echo "[RELEASE] WARNING: released with checks not PASS:$BAD (RELEASE_FORCE=1)"

# The timing models and the black box are made once per run: by make finish (black box) and extract_models.sh
for c in $CORNERS; do
  [ -e "$RUN/etm/${TOP}_$c.lib" ] || { "$REPO/scripts/signoff/sta/extract_models.sh" "$RUN" || exit 1; break; }
done
[ -e "$RUN/${TOP}_bb.v" ] || python3 "$REPO/scripts/common/write_blackbox.py" "$RUN/$TOP.v" "$RUN/${TOP}_bb.v" "$TOP" || exit 1

mkdir -p "$OUT"
rm -f "$OUT/$TOP".* "$OUT/${TOP}"_*.lib "$OUT/${TOP}_blackbox.v" "$OUT/sha256sums.txt"
cp "$RUN/$TOP.gds" "$RUN/$TOP.lef" "$RUN/$TOP.v" "$OUT/" || exit 1
cp "$RUN/${TOP}_bb.v" "$OUT/${TOP}_blackbox.v" || exit 1
for c in $CORNERS; do cp "$RUN/etm/${TOP}_$c.lib" "$OUT/" || exit 1; done
# one line per file, in C-locale name order ("." before "_", as in the v1.0.0 release)
( cd "$OUT" && export LC_ALL=C && sha256sum "$TOP".* "$TOP"_* ) > "$OUT/sha256sums.txt.tmp" && mv "$OUT/sha256sums.txt.tmp" "$OUT/sha256sums.txt"
echo "[RELEASE] $(wc -l < "$OUT/sha256sums.txt") files and sha256sums.txt in $OUT"
cat "$OUT/sha256sums.txt"
