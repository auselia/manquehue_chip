#!/bin/bash
# Chip-level LVS (KLayout) of outputs/chip_final: GDS against the chip netlist, through make lvs.
# The SRAMs, the IO pads and the wafer.space IPs are black boxes (metal, vias and pin labels kept), so this checks the
# croc logic and its connections to the pads and the pad ring, not the inside of the foundry cells.
# The wafer.space IPs have no devices and no pins: they extract to nothing, so their instances leave the schematic.
# Result in outputs/chip_lvs/lvs/lvs_compare_summary.txt.
set -e
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC=$REPO/outputs/chip_final
OUT=$REPO/outputs/chip_lvs
KIT=${LVS_PDK_KIT:-$HOME/.ciel/gf180mcuD/libs.ref}
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$SRC/chip_top.gds" "$OUT/"
grep -v '^gf180mcu_ws_ip__' "$SRC/chip_top.v" > "$OUT/chip_top.v"
IO_CDL=$KIT/gf180mcu_fd_io/cdl/gf180mcu_fd_io.cdl
SRAM_CDL=$(ls "$KIT"/gf180mcu_fd_ip_sram/cdl/gf180mcu_fd_ip_sram__sram*.cdl)
BB="$(basename -s .cdl $SRAM_CDL | tr '\n' ' ') $(grep -o 'gf180mcu_fd_io__[a-z0-9_]*' "$OUT/chip_top.v" | sort -u | tr '\n' ' ')"
BB="$BB gf180mcu_ws_ip__logo gf180mcu_ws_ip__marker gf180mcu_ws_ip__project_id gf180mcu_ws_ip__qrcode_id gf180mcu_ws_ip__shuttle_id"
make -C "$REPO" lvs TOP=chip_top GDS="$OUT/chip_top.gds" VLOG="$OUT/chip_top.v" \
    LVS_BLACKBOX_CDL="$SRAM_CDL $IO_CDL" LVS_BLACKBOX_CELLS="$BB"
