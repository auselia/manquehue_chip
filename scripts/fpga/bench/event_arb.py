#!/usr/bin/env python3
# Plays one event every 2 ms with the MSOX4024A WaveGen (8192 points per 2 ms, 244 ns each), quiet (0 V) in between,
# so WAKE_N releases between events. The event starts 200 us into the period.
#   python3 event_arb.py hit <carrier Hz> <peak V> [rise us] [decay us]   synthetic acoustic-emission hit: linear rise,
#                                                                          exponential decay, the carrier inside
#   python3 event_arb.py cap <capture.csv>                                 a scope capture (250 us) as one event
# Writes event_arb_last.npz (the played period, t and v) for event_check.py.
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scope import Scope

NPTS, T, T0 = 8192, 2e-3, 200e-6
t = np.arange(NPTS) * T / NPTS
kind = sys.argv[1]
if kind == "hit":
    f, pk = float(sys.argv[2]), float(sys.argv[3])
    rise = float(sys.argv[4]) * 1e-6 if len(sys.argv) > 4 else 20e-6
    dec = float(sys.argv[5]) * 1e-6 if len(sys.argv) > 5 else 80e-6
    u = t - T0
    env = np.where(u < 0, 0, np.where(u < rise, u / rise, np.exp(-(u - rise) / dec)))
    v = pk * env * np.sin(2 * np.pi * f * np.maximum(u, 0))
    label = f"hit {f / 1e3:.0f} kHz, {pk * 1e3:.0f} mV peak, rise {rise * 1e6:.0f} us, decay {dec * 1e6:.0f} us"
else:
    d = np.loadtxt(sys.argv[2], delimiter=",", skiprows=1)
    tc, vc = d[:, 0] - d[0, 0], d[:, 1] - d[:, 1].mean()
    k = max(1, int(round((T / NPTS) / np.median(np.diff(tc)))))   # average over each new point (no aliasing)
    vs = np.convolve(vc, np.ones(k) / k, mode="same")
    u = t - T0
    v = np.where((u >= 0) & (u <= tc[-1]), np.interp(u, tc, vs), 0.0)
    label = f"capture {os.path.basename(sys.argv[2])[:30]}, {len(vc)} points"
lo, hi = v.min(), v.max()
norm = 2 * (v - lo) / (hi - lo) - 1
sc = Scope(timeout=30)
sc.write(":WGEN:OUTP 0")
sc.write(":WGEN:FUNC ARB")
sc.write(":WGEN:ARB:INT 0")
sc.write(":WGEN:ARB:DATA " + ",".join(f"{x:.5f}" for x in norm))
sc.write(":WGEN:OUTP:LOAD ONEM")
sc.write(f":WGEN:FREQ {1 / T:.6f}")
sc.write(f":WGEN:VOLT {hi - lo:.5f}")
sc.write(f":WGEN:VOLT:OFFS {(hi + lo) / 2:.5f}")                    # 0 V of the waveform stays at 0 V
print(f"{label}; played pp {(hi - lo) * 1e3:.1f} mV, errors {sc.query(':SYST:ERR?')}")
sc.close()
np.savez(os.path.join(os.path.dirname(os.path.abspath(__file__)), "event_arb_last.npz"), t=t, v=v, label=label)
