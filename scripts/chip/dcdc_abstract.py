# Abstract of the DC-DC wrappers for Fusion Compiler (chip floorplan, CHIP_FLOORPLAN=1).
# usage (make chip_macros_ndm): klayout -b -r dcdc_abstract.py -rd gds_dir=<dir> -rd cells="<names>" -rd out=<dir>
#
# The wrappers are drawn in chip coordinates (their content is not at the cell origin). FC places a macro by the
# lower-left corner of its bounding box and ignores a LEF ORIGIN, so for each wrapper this writes:
#   <out>/<cell>.lef   CLASS BLOCK, SIZE = bounding box, no pins, OBS over the box on Metal1 to Metal5
#   <out>/<cell>.gds   the same layout moved so the box starts at (0, 0), for write_gds -merge_files
#   <out>/<cell>.loc   "llx lly": where the chip places it, so the layout lands where it was drawn
# Subcell names used by more than one wrapper get the wrapper name as prefix, so the merged chip GDS has no clash.
import pya

gds_dir = globals()["gds_dir"]
cells = globals()["cells"].split()
out = globals()["out"]
layers = ["Metal1", "Metal2", "Metal3", "Metal4", "Metal5"]

layouts = {}
for c in cells:
    ly = pya.Layout()
    ly.read(f"{gds_dir}/{c}.gds")
    layouts[c] = ly

seen = {}
for c, ly in layouts.items():
    for ci in ly.each_cell():
        if ci.name != c:
            seen.setdefault(ci.name, []).append(c)
shared = {n for n, owners in seen.items() if len(owners) > 1}

for c, ly in layouts.items():
    top = ly.cell(c)
    if top is None:
        raise SystemExit(f"ERROR: {c}.gds has no top cell {c}")
    for ci in ly.each_cell():
        if ci.name in shared:
            ci.name = f"{c}__{ci.name}"
    # Zero-area shapes hold no layout and fail the wafer.space precheck: the copy drops them
    zero = 0
    for ci in ly.each_cell():
        for li in ly.layer_indexes():
            dead = [sh for sh in ci.shapes(li).each() if (sh.is_polygon() or sh.is_box() or sh.is_path()) and sh.polygon.area() == 0]
            for sh in dead:
                ci.shapes(li).erase(sh)
            zero += len(dead)
    if zero:
        print(f"INFO: {c}: {zero} zero-area shapes removed")
    b = top.dbbox()
    llx, lly, w, h = b.left, b.bottom, b.width(), b.height()
    top.transform(pya.DTrans(-llx, -lly))
    ly.write(f"{out}/{c}.gds")
    with open(f"{out}/{c}.loc", "w") as f:
        f.write(f"{llx:.3f} {lly:.3f}\n")
    obs = "".join(f"    LAYER {l} ;\n      RECT 0 0 {w:.3f} {h:.3f} ;\n" for l in layers)
    with open(f"{out}/{c}.lef", "w") as f:
        f.write(f"""VERSION 5.7 ;
BUSBITCHARS "[]" ;
DIVIDERCHAR "/" ;
MACRO {c}
  CLASS BLOCK ;
  FOREIGN {c} 0 0 ;
  ORIGIN 0 0 ;
  SIZE {w:.3f} BY {h:.3f} ;
  SYMMETRY X Y ;
  OBS
{obs}  END
END {c}
END LIBRARY
""")
    print(f"INFO: {c}: box ({llx:.3f}, {lly:.3f}) {w:.3f} x {h:.3f} um")
print(f"INFO: renamed shared subcells: {len(shared)}")
