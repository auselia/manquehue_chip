"""Bit-accurate golden model of the AE-FFT accelerator (fft_hwpe).

One block: 128 signed 16-bit samples in, spectrum features out.
Every operation here is an integer operation that the RTL repeats.  Names follow the register map of
doc/spec_fft.tex (SETUP0, SETUP1, THRESH, STATUS).

Contract of the numeric steps (the RTL must match all of them):
  d  = sample - DC_OFFSET                         (17-bit, no clip)
  g  = clip16(d << GAIN_SHIFT)                    (SAT if it clipped)
  TD = sum((g*g) >> 10)                           (32-bit saturating, SAT if it saturated)
  xw = (g * HANN[n] + 2^14) >> 15                 (HANN[n] = (32768 - cos(2 pi n/128)) >> 1, from the ROM)
  z[m] = xw[2m] + j*xw[2m+1]                      (64 complex values)
  Z  = 64-point FFT of z, radix-2 DIT, 6 stages; each butterfly rounds the twiddle product
       ((c*u + 2^14) >> 15) and then halves both outputs with round-half-up ((v + 1) >> 1),
       then clips them to 16 bits (SAT if it clipped)
  X[k] = Xe[k] + W128^k * Xo[k]  for k = 0..64    (rounded halving of sums, rounded Q15 product)
  P[k] = min((Xr^2 + Xi^2) >> EN_SHIFT, 2^32 - 1) (Xr and Xi are 18-bit signed; SAT if it clipped)
  features over k = KMIN..64:  PEAK (lowest bin wins a tie), TOTAL; BAND over [BAND_LO, BAND_HI] within them
  BAND_OK = BAND*256 >= TOTAL*BAND_THR
  DECAY   = PREV_VALID and TD*256 < TD_PREV*DECAY_THR
  then TD_PREV = TD and PREV_VALID = 1
"""
import numpy as np

N = 128
M = 64
MASK32 = (1 << 32) - 1


def q15(v):
    return int(np.clip(np.round(v * 32768), -32768, 32767))


COS_ROM = np.array([q15(np.cos(2 * np.pi * k / N)) for k in range(33)], dtype=np.int64)   # 33 entries, k = 0..32


def cos_k(k):
    """cos(2*pi*k/128) for k = 0..64 from the 33-entry ROM."""
    return int(COS_ROM[k]) if k <= 32 else -int(COS_ROM[64 - k])


def sin_k(k):
    """sin(2*pi*k/128) for k = 0..64 from the 33-entry ROM."""
    return int(COS_ROM[32 - k]) if k <= 32 else int(COS_ROM[k - 32])


def hann_n(n):
    """Periodic Hann window, Q15, n = 0..127, from the same ROM: (1 - cos) / 2, floor.  Max is 32767."""
    c = cos_k(n) if n <= 64 else cos_k(128 - n)
    return (32768 - c) >> 1


HANN = np.array([hann_n(n) for n in range(N)], dtype=np.int64)


def rshift_round(v, s):
    return (v + (1 << (s - 1))) >> s


def clip16(v):
    return int(max(-32768, min(32767, v)))


def sat32(v):
    return min(v, MASK32)


def bitrev6(i):
    return int(format(i, '06b')[::-1], 2)


def run_block(samples, cfg, state):
    """samples: 128 ints.  cfg: dict of register fields.  state: dict(td_prev, prev_valid), updated in place."""
    gs, es = cfg['gain_shift'], cfg['en_shift']
    sat = 0
    g = []
    for s in samples:
        d = int(s) - cfg['dc_offset']
        v = d << gs
        c = clip16(v)
        sat |= (c != v)
        g.append(c)
    td = 0
    for v in g:
        td += (v * v) >> 10
    if td > MASK32:
        td, sat = MASK32, 1
    xw = [rshift_round(g[n] * int(HANN[n]), 15) for n in range(N)]
    re = [xw[2 * m] for m in range(M)]
    im = [xw[2 * m + 1] for m in range(M)]
    # bit-reversed load
    r = [0] * M
    i = [0] * M
    for m in range(M):
        r[bitrev6(m)], i[bitrev6(m)] = re[m], im[m]
    for s in range(6):
        half = 1 << s
        span = half << 1
        for gb in range(0, M, span):
            for b in range(half):
                lo, up = gb + b, gb + b + half
                k = b * (M // span) * 2                    # W_128^k with k even: the 64-point twiddle
                c, sn = cos_k(k), sin_k(k)
                pr = rshift_round(c * r[up] + sn * i[up], 15)
                pi_ = rshift_round(c * i[up] - sn * r[up], 15)
                lr, li = r[lo], i[lo]
                outs = [rshift_round(lr + pr, 1), rshift_round(li + pi_, 1),
                        rshift_round(lr - pr, 1), rshift_round(li - pi_, 1)]
                for o in outs:
                    sat |= (clip16(o) != o)
                r[lo], i[lo], r[up], i[up] = [clip16(o) for o in outs]
    Z = list(zip(r, i))
    zr = r + [r[0]]
    zi = i + [i[0]]
    Xr = [0] * (M + 1)
    Xi = [0] * (M + 1)
    for k in range(M + 1):
        ar, ai = zr[k], zi[k]
        br, bi = zr[M - k], -zi[M - k]
        er, ei = rshift_round(ar + br, 1), rshift_round(ai + bi, 1)
        dr, di = rshift_round(ar - br, 1), rshift_round(ai - bi, 1)
        o_r, o_i = di, -dr
        c, sn = cos_k(k), -sin_k(k)                         # W128^k = cos - j sin
        Xr[k] = er + rshift_round(c * o_r - sn * o_i, 15)
        Xi[k] = ei + rshift_round(c * o_i + sn * o_r, 15)
    P = [(Xr[k] * Xr[k] + Xi[k] * Xi[k]) >> es for k in range(M + 1)]
    for k in range(M + 1):
        if P[k] > MASK32:
            P[k], sat = MASK32, 1
    kmin, blo, bhi = cfg['kmin'], cfg['band_lo'], cfg['band_hi']
    pk, pkp, tot, band = kmin, -1, 0, 0
    for k in range(kmin, M + 1):
        if P[k] > pkp:
            pk, pkp = k, P[k]
        tot += P[k]
        if blo <= k <= bhi:
            band += P[k]
    if tot > MASK32:
        tot, sat = MASK32, 1
    if band > MASK32:
        band, sat = MASK32, 1
    pkp = max(pkp, 0)
    if pkp > MASK32:
        pkp, sat = MASK32, 1
    dump = []
    for k in range(M + 1):
        a, b = clip16(Xr[k]), clip16(Xi[k])
        sat |= (a != Xr[k]) or (b != Xi[k])
        dump.append((a, b))
    band_ok = int(band * 256 >= tot * cfg['band_thr'])
    decay = int(bool(state['prev_valid']) and td * 256 < state['td_prev'] * cfg['decay_thr'])
    td_prev_before = state['td_prev']
    state['td_prev'], state['prev_valid'] = td, 1
    return dict(xw=xw, Z=Z, X=dump, Xr=Xr, Xi=Xi, P=P, peak=pk, peak_pow=pkp, band=band, total=tot, td=td,
                td_prev_before=td_prev_before, td_prev=td, sat=int(sat), band_ok=band_ok, decay=decay,
                prev_valid=1)


def ref_spectrum(samples, cfg):
    """Floating-point reference of the accelerator output (true spectrum of the windowed block / 64)."""
    x = np.array([clip16((int(s) - cfg['dc_offset']) << cfg['gain_shift']) for s in samples], float)
    w = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N)
    return np.fft.rfft(x * w) / 64.0


def default_cfg(**kw):
    c = dict(gain_shift=3, en_shift=4, dc_offset=0, kmin=3, band_lo=8, band_hi=20, band_thr=179, decay_thr=192)
    c.update(kw)
    return c


def setup0(c):
    return (c['gain_shift'] & 0xF) | ((c['en_shift'] & 0xF) << 8) | ((c['dc_offset'] & 0xFFFF) << 16)


def setup1(c):
    return (c['kmin'] & 0x7F) | ((c['band_lo'] & 0x7F) << 8) | ((c['band_hi'] & 0x7F) << 16)


def thresh(c):
    return (c['band_thr'] & 0xFF) | ((c['decay_thr'] & 0xFF) << 8)


def status_bits(r):
    return (r['sat'] << 2) | (r['prev_valid'] << 3) | (r['band_ok'] << 4) | (r['decay'] << 5)


if __name__ == '__main__':
    rng = np.random.default_rng(0)
    t = np.arange(N)
    xs = np.round(3000 * np.sin(2 * np.pi * 20.3 * t / N) + 80 * rng.standard_normal(N)).astype(int)
    st = dict(td_prev=0, prev_valid=0)
    c = default_cfg(gain_shift=0)
    r = run_block(xs, c, st)
    ref = ref_spectrum(xs, c)
    err = np.abs(np.array(r['Xr']) + 1j * np.array(r['Xi']) - ref)
    print('max |X - ref| over bins 3..64: %.2f codes; peak bin %d (float: %d)' %
          (err[3:].max(), r['peak'], 3 + int(np.argmax(np.abs(ref[3:])))))
