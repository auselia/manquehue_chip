#!/usr/bin/env python3
# Compares what croc's ADC recorded (step 3 -DDUMP blocks, UART log) with what the chain should give for a scope
# capture played by the WaveGen (cav_arb.py): the capture, shaped by the AFE gain measured on 9 Nov 2026 (magnitude
# only, the phase is not known), sampled at 1.000 MSPS with aliasing. The capture repeats every 250 us = 250 samples.
#   python3 cav_compare.py <capture.csv> <croc uart log>
# Per band: power (codes^2) expected and measured, from the averaged 128-point Hann spectrum of the blocks (8 croc
# blocks, every 128-sample window of the expected 250-sample period). Peak bin of the averaged spectrum (bin = 7.8125 kHz).
import sys, re, numpy as np

FS, NB = 1.0e6, 128
SKIP = 8
# AFE: measured codes per mV peak at SIG_IN, 9 Nov 2026 (200 mVpp sweep, 250 kHz = 10.66 codes/mV). 10 kHz is the
# simulation value (-40.5 dB below 250 kHz), the measurement there was not usable. Above 1.75 MHz: -20 dB/decade.
F_DB = [(1e3, -80.0), (10e3, -40.5), (30e3, -23.3), (100e3, -3.3), (250e3, 0.0), (480e3, -2.3), (1.1e6, -13.9),
        (1.75e6, -21.6), (17.5e6, -41.6)]
G250 = 10.66  # codes per mV peak at 250 kHz

def afe(f):
    lf = np.log10(np.maximum(f, 1.0))
    db = np.interp(lf, [np.log10(a) for a, _ in F_DB], [b for _, b in F_DB])
    return G250 * 1e3 * 10 ** (db / 20)  # codes per volt

def expected(csv, npts=8192):
    d = np.loadtxt(csv, delimiter=",", skiprows=1)
    t, v = d[:, 0], d[:, 1] - d[:, 1].mean()
    T = (t[-1] - t[0]) * len(t) / (len(t) - 1)
    k = len(v) // npts                                      # same resampling as cav_arb.py
    y = np.convolve(np.interp(t[0] + np.arange(npts * k) * T / (npts * k), t, v), np.ones(k) / k, mode="same")[::k]
    C = np.fft.rfft(y) / npts                               # Fourier series of the played waveform
    fk = np.arange(len(C)) / T
    H = afe(fk); H[0] = 0
    n = np.arange(int(round(T * FS)))                       # 250 samples at 1 MSPS
    ph = np.exp(2j * np.pi * np.outer(n / FS, fk))
    x = (ph @ (C * H)).real * 2                             # real signal from the one-sided series (DC removed)
    return x

def croc_blocks(log):
    out, cur = [], None
    for line in open(log, errors="replace"):
        line = line.strip()
        if line.startswith("block "): cur = []; out.append(cur); continue
        if cur is not None and re.fullmatch(r"([0-9a-f]{8}\s*)+", line):
            for w in line.split():
                u = int(w, 16) & 0x3FFF
                cur.append(u - 0x4000 if u & 0x2000 else u)
    return [np.array(b[SKIP:], float) for b in out if len(b) == NB]

def avg_spec(wins):
    w = np.hanning(len(wins[0]))
    return np.mean([np.abs(np.fft.rfft((x - x.mean()) * w)) ** 2 for x in wins], axis=0) / ((w ** 2).sum() * len(w))

def main():
    x = expected(sys.argv[1])
    bl = croc_blocks(sys.argv[2])
    L = NB - SKIP
    ew = [np.roll(x, -s)[:L] for s in range(len(x))]
    se, sm = avg_spec(ew), avg_spec(bl)
    fr = np.fft.rfftfreq(L, 1 / FS)
    print(f"croc blocks: {len(bl)}, {L} samples each (first {SKIP} skipped)")
    print(f"rms (codes): expected {np.mean([w.std() for w in ew]):.1f}, croc {np.mean([b.std() for b in bl]):.1f}")
    print(f"peak frequency of the averaged spectrum: expected {fr[1 + np.argmax(se[1:])] / 1e3:.1f} kHz, "
          f"croc {fr[1 + np.argmax(sm[1:])] / 1e3:.1f} kHz")
    print("band (kHz)        expected   croc   (rms codes in the band)")
    for a, b in [(0, 50e3), (50e3, 150e3), (150e3, 350e3), (350e3, 500e3)]:
        m = (fr >= a) & (fr < b) & (fr > 0)
        pe, pm = np.sqrt(se[m].sum() * 2), np.sqrt(sm[m].sum() * 2)
        print(f"{a / 1e3:5.0f} to {b / 1e3:5.0f}    {pe:9.1f} {pm:6.1f}")

main()
