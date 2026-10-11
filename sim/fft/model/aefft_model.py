"""Bit-accurate golden model of the AE-FFT accelerator (fft_hwpe).

One block: 128 signed 16-bit samples in, spectrum features out.
Every operation here is an integer operation that the RTL repeats.  Names follow the register map of
doc/spec_fft.tex (SETUP0, SETUP1, THRESH, STATUS).

Contract of the numeric steps (the RTL must match all of them):
  d  = sample - DC_OFFSET                         (17-bit, no clip)
  g  = clip16(d << GAIN_SHIFT)                    (SAT if it clipped)
  TD = sum((g*g) >> 10)                           (32-bit; cannot saturate for 128 samples)
  xw = (g * HANN[n] + 2^14) >> 15                 (HANN[n] = (32768 - cos(2 pi n/128)) >> 1, from the ROM)
  z[m] = xw[2m] + j*xw[2m+1]                      (64 complex values, stored in place, natural order)
  Z  = 64-point FFT, radix-2 DIF in place, 6 stages, output in bit-reversed order.  Per butterfly:
         lo' = clip16((lo + up + 1) >> 1)
         d   = clip16((lo - up + 1) >> 1)
         up' = clip16((W * d + 2^14) >> 15),  W = c - j s, c = cos, s = +sin of 2 pi k/128, k = b << (stage + 1)
  X[k] = Xe[k] + W128^k * Xo[k]  for k = 0..64   (Xe, Xo halved with rounding, Xo components clipped to 16 bit)
  X16  = clip16(X)                                (SAT if it clipped)
  P[k] = (X16r^2 + X16i^2) >> EN_SHIFT           (fits 32 bit)
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

    def clip(v):
        nonlocal sat
        c = clip16(v)
        sat |= int(c != v)
        return c

    g = [clip((int(s) - cfg['dc_offset']) << gs) for s in samples]
    td = 0
    for v in g:
        td += (v * v) >> 10
    xw = [rshift_round(g[n] * int(HANN[n]), 15) for n in range(N)]
    r = [xw[2 * m] for m in range(M)]
    i = [xw[2 * m + 1] for m in range(M)]
    # in-place radix-2 DIF, natural order in, bit-reversed order out; every stage halves with rounding
    for s in range(6):
        half = 32 >> s
        for n in range(32):
            b = n & (half - 1)
            lo = ((n & ~(half - 1)) << 1) | b
            up = lo + half
            k = b << (s + 1)                                   # W_128^k, k even: the 64-point twiddle
            c, sn = cos_k(k), sin_k(k)
            sr = clip(rshift_round(r[lo] + r[up], 1))
            si = clip(rshift_round(i[lo] + i[up], 1))
            dr = clip(rshift_round(r[lo] - r[up], 1))
            di = clip(rshift_round(i[lo] - i[up], 1))
            pr = clip(rshift_round(c * dr + sn * di, 15))
            pi_ = clip(rshift_round(c * di - sn * dr, 15))
            r[lo], i[lo], r[up], i[up] = sr, si, pr, pi_
    Z = [(r[bitrev6(k)], i[bitrev6(k)]) for k in range(M)]     # natural order from the bit-reversed memory
    mem_image = [(r[a], i[a]) for a in range(M)]               # what is left in the buffer after the run
    zr = [z[0] for z in Z] + [Z[0][0]]
    zi = [z[1] for z in Z] + [Z[0][1]]
    Xr = [0] * (M + 1)
    Xi = [0] * (M + 1)
    X16 = []
    P = []
    for k in range(M + 1):
        ar, ai = zr[k], zi[k]
        yr, yi = zr[M - k], zi[M - k]
        er = rshift_round(ar + yr, 1)
        ei = rshift_round(ai - yi, 1)
        dr = clip(rshift_round(ar - yr, 1))
        di = clip(rshift_round(ai + yi, 1))
        o_r, o_i = di, -dr
        c, sn = cos_k(k), sin_k(k)
        Xr[k] = er + rshift_round(c * o_r + sn * o_i, 15)
        Xi[k] = ei + rshift_round(c * o_i - sn * o_r, 15)
        a, b = clip(Xr[k]), clip(Xi[k])
        X16.append((a, b))
        P.append((a * a + b * b) >> es)
    kmin, blo, bhi = cfg['kmin'], cfg['band_lo'], cfg['band_hi']
    pk, pkp, tot, band = kmin, 0, 0, 0
    first = True
    for k in range(kmin, M + 1):
        if first or P[k] > pkp:
            pk, pkp = k, P[k]
        first = False
        tot += P[k]
        if blo <= k <= bhi:
            band += P[k]
    if tot > MASK32:
        tot, sat = MASK32, 1
    if band > MASK32:
        band, sat = MASK32, 1
    band_ok = int(band * 256 >= tot * cfg['band_thr'])
    decay = int(bool(state['prev_valid']) and td * 256 < state['td_prev'] * cfg['decay_thr'])
    td_prev_before = state['td_prev']
    state['td_prev'], state['prev_valid'] = td, 1
    return dict(xw=xw, Z=Z, X=X16, Xr=Xr, Xi=Xi, P=P, peak=pk, peak_pow=pkp, band=band, total=tot, td=td,
                td_prev_before=td_prev_before, td_prev=td, sat=int(sat), band_ok=band_ok, decay=decay,
                prev_valid=1, mem_image=mem_image)


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
