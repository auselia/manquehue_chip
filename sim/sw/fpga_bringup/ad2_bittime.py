#!/usr/bin/env python3
# Measures the UART bit time on DIO 0 with the AD2 logic analyzer: waits for the first falling edge (a start bit),
# records 16384 samples at 2 MHz (8 ms), prints the pulse widths and the bit time they give.
#   python3 ad2_bittime.py [ready_file]
import sys, time
from collections import Counter
from ctypes import cdll, c_int, c_uint, c_double, c_byte, byref, create_string_buffer, c_uint16

dwf = cdll.LoadLibrary("/Library/Frameworks/dwf.framework/dwf")
N, DIV = 16384, 50  # 100 MHz / 50 = 2 MHz
h = c_int()
if dwf.FDwfDeviceOpen(c_int(-1), byref(h)) == 0 or h.value == 0:
    sys.exit("AD2 open failed")
hz = c_double(); dwf.FDwfDigitalInInternalClockInfo(h, byref(hz))
dwf.FDwfDigitalInDividerSet(h, c_int(DIV))
dwf.FDwfDigitalInSampleFormatSet(h, c_int(16))
dwf.FDwfDigitalInBufferSizeSet(h, c_int(N))
dwf.FDwfDigitalInTriggerSourceSet(h, c_byte(3))  # trigsrcDetectorDigitalIn
dwf.FDwfDigitalInTriggerPositionSet(h, c_uint(N - 100))
dwf.FDwfDigitalInTriggerSet(h, c_int(0), c_int(0), c_int(0), c_int(1))  # falling edge on DIO 0
dwf.FDwfDigitalInConfigure(h, c_int(0), c_int(1))
if len(sys.argv) > 1: open(sys.argv[1], "w").close()
sts = c_byte(); t0 = time.time()
while True:
    dwf.FDwfDigitalInStatus(h, c_int(1), byref(sts))
    if sts.value == 2: break  # DwfStateDone
    if time.time() - t0 > 30: dwf.FDwfDeviceCloseAll(); sys.exit("no edge on DIO 0 in 30 s")
    time.sleep(0.01)
buf = (c_uint16 * N)()
dwf.FDwfDigitalInStatusData(h, buf, c_int(2 * N))
dwf.FDwfDeviceCloseAll()

fs = hz.value / DIV
bits = [b & 1 for b in buf]
runs, cur, n = [], bits[0], 0
for b in bits:
    if b == cur: n += 1
    else: runs.append((cur, n)); cur, n = b, 1
runs.append((cur, n))
print(f"sample rate {fs/1e6:.1f} MHz, {len(runs)} runs, idle level at start {bits[0]}")
print("first 40 runs (level, us):", [(l, round(c / fs * 1e6, 1)) for l, c in runs[1:41]])
w = Counter(round(c / fs * 1e6, 1) for l, c in runs[1:-1])
print("most common widths (us: count):", w.most_common(8))
shortest = min(c for l, c in runs[1:-1]) / fs
print(f"shortest pulse {shortest*1e6:.2f} us -> {1/shortest:.0f} baud if that is one bit")
