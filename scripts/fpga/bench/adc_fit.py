#!/usr/bin/env python3
# Sine fit of the ADC blocks that step 3 prints with -DDUMP=n (./build.sh s3_adc -DDUMP=8).
#   python3 adc_fit.py <uart log> [expected frequency in Hz]
# croc samples at 1.000 MSPS (20 clocks per frame at 20 MHz), 128 samples per block, ADS7057 14-bit two's complement,
# 1 code = 0.403 mV at the ADC (6.6 V / 16384). The first SKIP samples of a block are left out (the reader start
# transient seen on 9 Nov 2026: up to about 8 samples). The fit
# searches 5 kHz to 500 kHz: closer to DC a sine and the offset cannot be told apart in one block. Per block: frequency, amplitude (peak, codes and mV), offset, and
# SINAD from the fit residual (rough with 124 samples). No numpy: plain Python.
import math, re, sys

FS, MV, SKIP, FMIN = 1.0e6, 6600.0 / 16384, 8, 5.0e3

def sx14(v):
    v &= 0x3FFF
    return v - 0x4000 if v & 0x2000 else v

def blocks(text):
    out, cur = [], None
    for line in text.splitlines():
        if line.startswith("block "):
            cur = []; out.append(cur); continue
        if line.startswith(("cycles", "dump end", "STEP3")):
            continue
        if cur is not None and re.fullmatch(r"(\s*[0-9a-f]{8})+\s*", line):
            cur += [sx14(int(w, 16)) for w in line.split()]
    return [b for b in out if len(b) == 128]

def lsq(x, f):
    # y = a cos + b sin + c at frequency f: 3x3 normal equations, returns (a, b, c, rms residual)
    n = len(x); w = 2 * math.pi * f / FS
    cs = [math.cos(w * (i + SKIP)) for i in range(n)]; sn = [math.sin(w * (i + SKIP)) for i in range(n)]
    cols = [cs, sn, [1.0] * n]
    m = [[sum(p * q for p, q in zip(ci, cj)) for cj in cols] for ci in cols]
    r = [sum(p * q for p, q in zip(ci, x)) for ci in cols]
    for k in range(3):  # Gauss elimination
        piv = m[k][k] or 1e-12
        for j in range(k + 1, 3):
            g = m[j][k] / piv
            m[j] = [a - g * b for a, b in zip(m[j], m[k])]; r[j] -= g * r[k]
    s = [0.0] * 3
    for k in (2, 1, 0):
        s[k] = (r[k] - sum(m[k][j] * s[j] for j in range(k + 1, 3))) / (m[k][k] or 1e-12)
    res = [xi - (s[0] * c + s[1] * q + s[2]) for xi, c, q in zip(x, cs, sn)]
    return s[0], s[1], s[2], math.sqrt(sum(e * e for e in res) / n)

def fit(x):
    best = None
    for k in range(int(FMIN * 1280 / FS), 640):  # coarse: 0.78 kHz steps, FMIN up to Nyquist (500 kHz)
        f = k * FS / 1280
        e = lsq(x, f)[3]
        if best is None or e < best[1]: best = (f, e)
    f, step = best[0], FS / 1280
    for _ in range(30):  # refine
        cand = [(g, lsq(x, g)[3]) for g in (f - step, f, f + step) if FMIN <= g < FS / 2]
        f = min(cand, key=lambda t: t[1])[0]; step /= 2
    a, b, c, rms = lsq(x, f)
    amp = math.hypot(a, b)
    sinad = 20 * math.log10((amp / math.sqrt(2)) / rms) if rms > 0 and amp > 0 else float("nan")
    return f, amp, c, rms, sinad

def main():
    text = open(sys.argv[1], errors="replace").read()
    fexp = float(sys.argv[2]) if len(sys.argv) > 2 else None
    bl = blocks(text)
    if not bl: sys.exit("no complete 128-sample blocks in the log")
    print(f"{len(bl)} block(s), fit on samples {SKIP}..127, 1 code = {MV:.3f} mV")
    print(" blk   freq (kHz)   amp (codes)   amp (mV pk)   offset (codes)   resid rms   SINAD (dB)   min..max")
    amps = []
    for i, b in enumerate(bl):
        x = b[SKIP:]
        f, amp, c, rms, sinad = fit(x)
        amps.append(amp)
        print(f"{i:4d} {f/1e3:12.3f} {amp:13.1f} {amp*MV:13.1f} {c:16.1f} {rms:11.1f} {sinad:12.1f}   {min(x)}..{max(x)}")
    mean = sum(amps) / len(amps)
    print(f"mean amplitude {mean:.1f} codes = {mean*MV:.1f} mV peak at the ADC")
    if fexp:
        fold = abs(fexp - round(fexp / FS) * FS)
        print(f"expected {fexp/1e3:.3f} kHz appears at {fold/1e3:.3f} kHz at 1.000 MSPS")

main()
