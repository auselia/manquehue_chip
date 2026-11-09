#!/usr/bin/env python3
# Loads a scope capture (time_s,volts CSV, e.g. 62500 points at 4 ns) into the MSOX4024A WaveGen as an arbitrary
# waveform: DC removed, resampled to NPTS points over the record, normalised to -1..+1, repeated at 1/record length,
# amplitude (Vpp) = the capture's peak to peak, offset 0. Output load High-Z.
#   python3 cav_arb.py <capture.csv> [npts]
import sys, numpy as np
sys.path.insert(0, __import__("os").path.dirname(__file__))
from scope import Scope

f = sys.argv[1]
npts = int(sys.argv[2]) if len(sys.argv) > 2 else 8192
d = np.loadtxt(f, delimiter=",", skiprows=1)
t, v = d[:, 0], d[:, 1] - d[:, 1].mean()
T = (t[-1] - t[0]) * len(t) / (len(t) - 1)                 # record length (one period of the repeated waveform)
tn = t[0] + np.arange(npts) * T / npts
y = np.interp(tn, t, v)
# resampling to npts points is a decimation: average over each new point to keep it free of aliasing
k = len(v) // npts
if k > 1:
    y = np.convolve(np.interp(t[0] + np.arange(npts * k) * T / (npts * k), t, v), np.ones(k) / k, mode="same")[::k]
lo, hi = y.min(), y.max()
norm = 2 * (y - lo) / (hi - lo) - 1
vpp, off = hi - lo, (hi + lo) / 2                           # off: DC of the normalised shape, kept at 0 V mean
sc = Scope(timeout=30)
sc.write(":WGEN:OUTP 0")
sc.write(":WGEN:FUNC ARB")
sc.write(":WGEN:ARB:INT 0")
sc.write(":WGEN:ARB:DATA " + ",".join(f"{x:.5f}" for x in norm))
sc.write(":WGEN:OUTP:LOAD ONEM")
sc.write(f":WGEN:FREQ {1 / T:.6f}")
sc.write(f":WGEN:VOLT {vpp:.5f}")
sc.write(f":WGEN:VOLT:OFFS {off:.5f}")
print(f"points {sc.query(':WGEN:ARB:DATA:ATTR:POIN?')}, freq {sc.query(':WGEN:FREQ?')}, "
      f"vpp {sc.query(':WGEN:VOLT?')}, offset {sc.query(':WGEN:VOLT:OFFS?')}, errors {sc.query(':SYST:ERR?')}")
print(f"capture: {len(v)} points, {T * 1e6:.1f} us, pp {vpp * 1e3:.1f} mV after resampling, rms {y.std() * 1e3:.2f} mV")
sc.close()
