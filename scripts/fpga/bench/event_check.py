#!/usr/bin/env python3
# Checks the step 7 UART log (s7_event): for each event, recomputes from croc's own samples
#   - the FFT features of the 4 blocks with the bit-exact model (aefft_model.py, step 7's register setup), and
#   - the envelope features with the same integer algorithm as s7_event.c,
# and compares them with what croc printed. Then compares the envelope features with the played signal
# (event_arb_last.npz) taken through an ideal chain: the AFE gain at the carrier and 1 MSPS, same algorithm.
#   python3 event_check.py <uart log> [codes per volt of the ideal chain, default 10660]
import os, re, sys, numpy as np
_here = os.path.dirname(os.path.abspath(__file__))
# the bit-exact FFT model: sim/fft/model in the repo, or a copy next to this script on the bench computer
sys.path[:0] = [_here, os.path.join(_here, '..', '..', 'fft', 'model')]
import aefft_model as M

PRE, ENVN = 64, 8
CFG = M.default_cfg(gain_shift=2, en_shift=4, dc_offset=0, kmin=3, band_lo=32, band_hi=39, band_thr=179, decay_thr=192)

def sx14(u):
    u &= 0x3FFF
    return u - 0x4000 if u & 0x2000 else u

def envelope(x):
    """Same steps as s7_event.c, integer only."""
    x = [int(v) for v in x]
    dc = sum(x[:PRE]) >> 6
    a = [abs(v - dc) for v in x]
    pk = max(a)
    env, s = [], 0
    for i, v in enumerate(a):
        s += v - (a[i - ENVN] if i >= ENVN else 0)
        env.append(s)
    emax = max(env); imax = env.index(emax)
    r10 = r90 = f90 = f10 = None; dur = 0; asum = an = 0
    for i, s in enumerate(env):
        s10 = 10 * s
        if r10 is None and s10 >= emax: r10 = i
        if r10 is not None and r90 is None and s10 >= 9 * emax: r90 = i
        if i >= imax and s10 >= 9 * emax: f90 = i; f10 = None
        if f90 is not None and f10 is None and i > f90 and s10 < emax: f10 = i
        if s10 >= 5 * emax: dur += 1
        if r10 is not None and f10 is None: asum += a[i]; an += 1
    mean = asum // an if an else 0
    return {"dc": dc, "env peak": emax, "env peak at": imax, "rise": r90 - r10, "fall": 0xFFFF if f10 is None else f10 - f90,
            "duration": dur, "onset": r10 - PRE, "peak": pk, "mean": mean, "crest x16": (pk << 4) // mean if mean else 0}

def parse(log):
    evs, cur, mode = [], None, None
    for line in open(log, errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("event ") and not line.startswith("event end"):
            cur = {"n": int(line.split()[1], 16), "fft": [], "feat": {}, "s": []}; evs.append(cur); mode = "feat"; continue
        if cur is None: continue
        if line.startswith("event end"): mode = None; continue
        if line.startswith("samples"): mode = "s"; continue
        if line.startswith("fft "):
            cur["fft"].append([int(w, 16) for w in line.split()[1:]]); continue
        if mode == "s":
            cur["s"] += [sx14(int(w, 16)) for w in line.split()]
        elif mode == "feat":
            m = re.fullmatch(r"(.+) ([0-9a-f]{8})", line)
            if m: cur["feat"][m.group(1)] = int(m.group(2), 16)
    return [e for e in evs if len(e["s"]) == 512]

def signed(v): return v - (1 << 32) if v >= 1 << 31 else v

def main():
    evs = parse(sys.argv[1])
    cpv = float(sys.argv[2]) if len(sys.argv) > 2 else 10660.0
    print(f"{len(evs)} complete event(s)")
    keys = ["rise", "fall", "duration", "onset", "peak", "mean", "crest x16", "env peak", "env peak at"]
    rows = []
    for e in evs:
        st = dict(td_prev=0, prev_valid=0)
        fft_ok = True
        for b in range(4):
            r = M.run_block(e["s"][128 * b:128 * b + 128], CFG, st)
            mine = [b, M.status_bits(r) | 2, r["peak"], r["band"], r["total"], r["td"]]
            got = e["fft"][b] if b < len(e["fft"]) else None
            if got is None or [got[0], got[1] & 0x3E, got[2], got[3], got[4], got[5]] != [mine[0], mine[1] & 0x3E] + mine[2:]:
                fft_ok = False
        ref = envelope(e["s"])
        feat = {k: (signed(v) if k == "onset" else v) for k, v in e["feat"].items()}
        env_ok = all(feat.get(k) == ref[k] for k in keys)
        bl = " ".join(f"bin {f[2]} {'B' if f[1] & 16 else '-'}{'D' if f[1] & 32 else '-'} {100 * f[3] / max(1, f[4]):.0f}%" for f in e["fft"])
        print(f"event {e['n']}: FFT {'= model' if fft_ok else 'DIFFERS from the model'}, envelope {'= recomputed' if env_ok else 'DIFFERS'}")
        print(f"  blocks: {bl}   (B = BAND_OK, D = DECAY, % = band share)")
        print("  croc: " + ", ".join(f"{k} {feat.get(k)}" for k in keys))
        if not env_ok: print("  recomputed: " + ", ".join(f"{k} {ref[k]}" for k in keys))
        rows.append(feat)
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "event_arb_last.npz")
    if os.path.exists(p) and rows:
        z = np.load(p)
        t, v = z["t"], z["v"]
        ts = np.arange(-PRE, 512 - PRE) * 1e-6
        on = t[np.argmax(np.abs(v) > 0)]                     # start of the played event
        x = np.round(np.interp(on + ts, t, v) * cpv).astype(int)
        ideal = envelope(x)
        print(f"ideal chain ({str(z['label'])}, {cpv:.0f} codes/V, event start at the trigger):")
        print("  ideal: " + ", ".join(f"{k} {ideal[k]}" for k in keys if k not in ('onset', 'env peak at')))
        for k in ["rise", "fall", "duration", "peak", "crest x16"]:
            vals = [r[k] for r in rows if r.get(k) is not None]
            print(f"  {k:10s} croc {np.mean(vals):8.1f} (min {min(vals)}, max {max(vals)})   ideal {ideal[k]}")

if __name__ == "__main__":
    main()
