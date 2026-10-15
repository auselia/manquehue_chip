#!/bin/bash
# The macro of a run through the wafer.space chip flow (LibreLane, pad ring) and the platform precheck.
# usage: verify/chip/run_chip_flow.sh      (env: RUN, SLOT, TEMPLATE_DIR, PRECHECK_DIR, COB=1 to run the precheck with --cob)
#
# Needs the template with the testmode_i pull-down (src/chip_core.sv, input_pd_w). The template is not modified:
# the macro paths are patched into a temporary copy of macros_5v.yaml that is deleted at the end.
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../env.sh"
step_begin chip
O=$STEP_DIR
T=$TEMPLATE_DIR
ST=PASS
grep -q "input_pd_w" "$T/src/chip_core.sv" || { summary status FAIL; summary reason "template has no testmode_i pull-down (src/chip_core.sv)"; exit 1; }
summary template_commit "$(git -C "$T" rev-parse --short HEAD)$(git -C "$T" diff --quiet || echo '+local changes')"

# extracted timing models of the macro, as the chip-level STA reads them
ls "$RUN"/etm/croc_soc_*.lib >/dev/null 2>&1 || "$REPO/scripts/pt/extract_models.sh" "$RUN" > "$O/etm.log" 2>&1

Y=$T/librelane/macros/macros_5v_verify.yaml
sed -e "s#dir::../../manquehue_chip/outputs/latest/#$RUN/#" "$T/librelane/macros/macros_5v.yaml" > "$Y"
trap 'rm -f "$Y"' EXIT
rm -rf "$O/views"
( cd "$T" && SLOT=$SLOT nix-shell --run "SRAM_DEFINE=SRAM_gf180mcu_fd_ip_sram librelane librelane/slots/slot_$SLOT.yaml librelane/macros/macros_5v_verify.yaml librelane/config.yaml --pdk gf180mcuD --pdk-root $PDK_ROOT --manual-pdk --scl gf180mcu_fd_sc_mcu7t5v0 --pad gf180mcu_fd_io --save-views-to $O/views" ) > "$O/librelane.log" 2>&1 || ST=FAIL
GDS=$O/views/gds/chip_top.gds
[ -s "$GDS" ] || { summary status FAIL; summary reason "no chip_top.gds"; exit 1; }
summary chip_gds "$GDS ($(stat -c %s "$GDS") bytes)"
summary chip_netlist "$O/views/pnl/chip_top.pnl.v"

# precheck
OPT=""; [ "${COB:-1}" = 1 ] && OPT="--cob"
( cd "$T" && nix-shell --run "export PDK_ROOT=$PDK_ROOT PDK=gf180mcuD PYTHONPATH=$PRECHECK_PYTHONPATH; cd $PRECHECK_DIR && python3 precheck.py --input $GDS --slot $SLOT $OPT --workers 2 --threads 5 --output $O/chip_top_checked.oas" ) > "$O/precheck.log" 2>&1 || ST=FAIL
grep -q "Precheck successfully completed" "$O/precheck.log" || ST=FAIL
MG=$(grep -o "[0-9]* Magic DRC errors" "$O/precheck.log" | head -1)
summary precheck "$(grep -o 'Precheck successfully completed' "$O/precheck.log" | head -1 || true) ${MG:+($MG)} ${OPT:+with $OPT}"
# chip-level gate-level simulation through the pads (testmode_i pad left open: the pull-down must hold it low)
if [ -s "$O/views/pnl/chip_top.pnl.v" ]; then
  ( cd "$T" && nix-shell --run "$REPO/verify/gls/run_chip_gls.sh $O/views/pnl/chip_top.pnl.v $RUN/croc_soc.v $O/gls_chip" ) > "$O/gls_chip.log" 2>&1 || true
  P=$(grep -h "PASS: GLS OK" "$O/gls_chip.log" | head -1)
  summary chip_gls "${P:-no PASS}"; [ -n "$P" ] || ST=FAIL
fi
summary status $ST
