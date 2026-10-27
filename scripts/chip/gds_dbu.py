# klayout -b -r gds_dbu.py -rd input=<gds> -rd output=<gds>
# FC write_gds stores the database unit as 0.0009999999999999998 um. The wafer.space precheck needs exactly 0.001.
# Only the stored unit changes: the coordinates are the same integers (1 nm).
import pya
ly = pya.Layout()
ly.read(globals()["input"])
if abs(ly.dbu - 0.001) > 1e-9:
    raise SystemExit("ERROR: dbu %g is not 1 nm" % ly.dbu)
ly.dbu = 0.001
ly.write(globals()["output"])
print("INFO: %s written with dbu %g" % (globals()["output"], ly.dbu))
