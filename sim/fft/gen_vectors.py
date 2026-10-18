#!/usr/bin/env python3
"""Generate RTL test vectors for fft_hwpe from the golden model.

Usage: gen_vectors.py [--captures DIR]

Synthetic cases always go in.  Scope captures go in when DIR holds the CSV files (the record files are
not stored in the repo, only the vectors that come from them).  Output: sim/fft/vectors/*.hex and
vectors.json.  Each hex file is for $readmemh, one 32-bit word per line.

  in.hex     64 words per block, sample 2m in [15:0], sample 2m+1 in [31:16]  (the layout of the SRAM)
  cfg.hex    4 words per block: SETUP0, SETUP1, THRESH, CTRL flags (bit 1 = CLR_PREV)
  exp_xw.hex 128 words per block: windowed sample (16-bit, sign extended)  -- checks the load stage
  exp_z.hex  64 words per block: {Zr, Zi} of the 64-point FFT, natural order
  exp_x.hex  65 words per block: {Xr, Xi} as the dump writes them (16-bit saturated)
  exp_p.hex  65 words per block: power per bin
  exp_f.hex  8 words per block: PEAK_BIN, PEAK_POW, BAND_ENERGY, TOTAL_ENERGY, TD_ENERGY, TD_PREV (the previous run's TD_ENERGY),
             STATUS flags [5:2], dump-saturation expected 0
"""
import argparse, glob, json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'model'))
import aefft_model as m

EVENT_FILES = ["20260921_165559_516_ch1_00012_-2.31_23.79us.csv", "20260921_180847_150_ch1_00003_-36.31_42.22us.csv",
               "20260921_184255_977_ch1_00004_-16.35_26.16us.csv", "20260921_210221_445_ch1_00006_-41.36_18.79us.csv",
               "20260922_114535_037_ch1_00009_-29.94_31.09us.csv", "20260922_121540_964_ch1_00010_-33.27_43.25us.csv",
               "20260922_154709_140_ch1_00014_-10.33_72.52us.csv"]
FS_OUT = 2.5e6


def load(f):
    d = np.genfromtxt(f, delimiter=',', skip_header=1)
    return d[:, 1] - np.median(d[:, 1]), 1 / (d[1, 0] - d[0, 0])


def afe(v, fs):
    """v0.1 analog chain: second-order high-pass 119 kHz and low-pass 495 kHz (magnitude only)."""
    n = len(v)
    n2 = 1 << int(np.ceil(np.log2(n * 2)))
    X = np.fft.rfft(np.pad(v - v[:20].mean(), (0, n2 - n)), n2)
    s = 1j * np.fft.rfftfreq(n2, 1 / fs)
    hp = (s / 119e3) ** 2 / ((s / 119e3) ** 2 + (s / 119e3) / 0.71 + 1)
    lp = 1 / ((s / 495e3) ** 2 + (s / 495e3) / 0.73 + 1)
    return np.fft.irfft(X * hp * lp, n2)[:n]


def decimate(x, fs_in, fs):
    X = np.fft.rfft(x)
    X[np.fft.rfftfreq(len(x), 1 / fs_in) > 0.45 * fs] = 0
    return np.fft.irfft(X, len(x))[::int(round(fs_in / fs))]


def adc(x, bits=14, full=3.3):
    return np.round(x / (2 * full / 2 ** bits)).astype(int)


class Suite:
    def __init__(self):
        self.blocks = []

    def sequence(self, name, blocks, cfg, auto_dc=False):
        """A run of consecutive blocks: the first one clears PREV_VALID, the rest see TD_PREV."""
        for j, b in enumerate(blocks):
            c = dict(cfg)
            b = np.asarray(b).astype(int)
            if auto_dc:
                c['dc_offset'] = int(np.round(b.mean()))
            self.blocks.append(dict(name='%s.%d' % (name, j), x=b, cfg=c, clr=int(j == 0)))


def synthetic(S):
    n = np.arange(128)
    d = m.default_cfg
    S.sequence('zeros', [np.zeros(128)], d(gain_shift=0))
    S.sequence('dc1000', [np.full(128, 1000)], d(gain_shift=0))
    S.sequence('dc1000_offset', [np.full(128, 1000)], d(gain_shift=0, dc_offset=1000))
    S.sequence('dc_min', [np.full(128, -32768)], d(gain_shift=0))
    imp = np.zeros(128); imp[0] = 20000
    S.sequence('impulse0', [imp], d(gain_shift=0))
    imp = np.zeros(128); imp[127] = -20000
    S.sequence('impulse127', [imp], d(gain_shift=0))
    imp = np.zeros(128); imp[64] = 32767
    S.sequence('impulse64_full', [imp], d(gain_shift=0))
    S.sequence('nyquist_full', [np.where(n % 2 == 0, 32767, -32768)], d(gain_shift=0))
    S.sequence('square_k4', [np.where((n // 16) % 2 == 0, 12000, -12000)], d(gain_shift=0))
    for k in list(range(0, 65, 4)) + [1, 2, 3, 7, 13, 20, 21, 63]:
        S.sequence('sine_k%d' % k, [np.round(8000 * np.sin(2 * np.pi * k * n / 128 + 0.3))], d(gain_shift=0))
    S.sequence('sine_full_k20', [np.round(32000 * np.sin(2 * np.pi * 20 * n / 128))], d(gain_shift=0))
    S.sequence('sine_clip_g1', [np.round(20000 * np.sin(2 * np.pi * 20 * n / 128))], d(gain_shift=1))
    S.sequence('sine_clip_g3', [np.round(6000 * np.sin(2 * np.pi * 5 * n / 128))], d(gain_shift=3))
    S.sequence('sine_k13_tone_like', [np.round(1500 * np.sin(2 * np.pi * 13.0 * n / 128 + 0.2 * j)) for j in range(4)], d(gain_shift=3))
    rng = np.random.default_rng(42)
    for i, (amp, gs) in enumerate([(30, 3), (300, 3), (3000, 0), (3000, 3), (16000, 0), (30000, 1)]):
        S.sequence('rand%d_a%d_g%d' % (i, amp, gs), [rng.integers(-amp, amp + 1, 128)], d(gain_shift=gs))
    # decaying burst, then a quiet block: DECAY must be set on the second block
    t = np.arange(256)
    burst = np.round(3000 * np.exp(-(t - 20).clip(0) / 18.0) * np.sin(2 * np.pi * 20.5 * t / 128) * (t >= 20))
    S.sequence('burst_decay', [burst[:128], burst[128:]], d(gain_shift=0))
    S.sequence('thresholds', [np.round(2000 * np.sin(2 * np.pi * 12 * n / 128)),
                              np.round(1950 * np.sin(2 * np.pi * 12 * n / 128)),
                              np.round(1000 * np.sin(2 * np.pi * 12 * n / 128))], d(gain_shift=0, decay_thr=128))
    # exact equality of the DECAY compare: TD of block 2 is exactly TD of block 1 * 64 / 256
    a = np.round(300 * np.sin(2 * np.pi * 9 * n / 128)).astype(int)
    S.sequence('decay_equal', [64 * a, 32 * a, 32 * a], d(gain_shift=0, decay_thr=64))
    S.sequence('kmin_band', [np.round(5000 * np.sin(2 * np.pi * 6 * n / 128) + 4000 * np.sin(2 * np.pi * 30 * n / 128))],
               d(gain_shift=0, kmin=10, band_lo=4, band_hi=40, en_shift=6))


def captured(S, root):
    quiet = sorted(glob.glob(os.path.join(root, '2026092*_all.csv')))
    if not quiet:
        print('no capture files in', root, '- synthetic cases only')
        return
    # trigger level from five of the quiet records, as in the project study
    sig = []
    for f in quiet:
        v, fs = load(f)
        y = afe(v, fs)[2000:]
        if np.std(y) < 0.01:
            sig.append(np.var(y))
    sigma = np.sqrt(np.mean(sig[:5]))
    for f in quiet:
        v, fs = load(f)
        y = adc(decimate(afe(v, fs), fs, FS_OUT)[200:])
        kind = 'tone' if np.std(y) > 40 else 'quiet'
        S.sequence('%s_%s' % (kind, os.path.basename(f)[9:23].replace('_', '')),
                   [y[i * 128:(i + 1) * 128] for i in range(len(y) // 128)], m.default_cfg(), auto_dc=True)
    for i, name in enumerate(EVENT_FILES):
        f = os.path.join(root, name)
        if not os.path.exists(f):
            continue
        v, fs = load(f)
        y = decimate(afe(v, fs), fs, FS_OUT)
        k = max(int(np.argmax(np.abs(y) > 5 * sigma)) - 1, 0)
        c = adc(y[k:])
        c = np.pad(c, (0, max(0, 256 - len(c))))
        S.sequence('event%d' % (i + 1), [c[:128], c[128:256]], m.default_cfg(), auto_dc=True)
    # firmware test: block 2 is block 1 with every sample halved (computed by the program itself)
    f = os.path.join(root, EVENT_FILES[0])
    if os.path.exists(f):
        v, fs = load(f)
        y = decimate(afe(v, fs), fs, FS_OUT)
        k = max(int(np.argmax(np.abs(y) > 5 * sigma)) - 1, 0)
        c0 = adc(y[k:])[:128]
        c0 = np.pad(c0, (0, 128 - len(c0)))
        S.sequence('fw_event1', [c0, c0 >> 1], m.default_cfg(), auto_dc=True)
    # gain sweep on one event
    f = os.path.join(root, EVENT_FILES[6])
    if os.path.exists(f):
        v, fs = load(f)
        y = decimate(afe(v, fs), fs, FS_OUT)
        k = max(int(np.argmax(np.abs(y) > 5 * sigma)) - 1, 0)
        c = adc(y[k:])
        for gs in range(0, 5):
            S.sequence('event7_g%d' % gs, [c[:128]], m.default_cfg(gain_shift=gs), auto_dc=True)


def w32(a, b):
    return ((a & 0xFFFF) << 16) | (b & 0xFFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--captures', default=os.path.expanduser('~/Downloads'))
    a = ap.parse_args()
    S = Suite()
    synthetic(S)
    captured(S, a.captures)
    outdir = os.path.join(HERE, 'vectors')
    os.makedirs(outdir, exist_ok=True)
    files = {k: [] for k in ('in', 'cfg', 'exp_xw', 'exp_z', 'exp_x', 'exp_p', 'exp_f')}
    info = []
    state = dict(td_prev=0, prev_valid=0)
    worst = 0.0
    for b in S.blocks:
        if b['clr']:
            state = dict(td_prev=0, prev_valid=0)
        x = np.clip(b['x'], -32768, 32767).astype(int)
        r = m.run_block(x, b['cfg'], state)
        for j in range(64):
            files['in'].append('%08x' % ((int(x[2 * j]) & 0xFFFF) | ((int(x[2 * j + 1]) & 0xFFFF) << 16)))
        files['cfg'] += ['%08x' % m.setup0(b['cfg']), '%08x' % m.setup1(b['cfg']), '%08x' % m.thresh(b['cfg']),
                         '%08x' % (b['clr'] << 1)]
        files['exp_xw'] += ['%08x' % (v & 0xFFFFFFFF) for v in r['xw']]
        files['exp_z'] += ['%08x' % w32(a_, b_) for a_, b_ in r['Z']]
        files['exp_x'] += ['%08x' % w32(a_, b_) for a_, b_ in r['X']]
        files['exp_p'] += ['%08x' % v for v in r['P']]
        files['exp_f'] += ['%08x' % v for v in (r['peak'], r['peak_pow'], r['band'], r['total'], r['td'],
                                                r['td_prev_before'], m.status_bits(r), 0)]
        # sanity against the floating-point reference when nothing clipped
        if not r['sat']:
            ref = m.ref_spectrum(x, b['cfg'])
            err = np.abs(np.array(r['Xr']) + 1j * np.array(r['Xi']) - ref)[3:].max()
            worst = max(worst, err)
        info.append(dict(name=b['name'], peak=r['peak'], band_ok=r['band_ok'], decay=r['decay'], sat=r['sat'],
                         td=r['td'], total=r['total'], band=r['band']))
    for k, v in files.items():
        with open(os.path.join(outdir, k + '.hex'), 'w') as f:
            f.write('\n'.join(v) + '\n')
    with open(os.path.join(outdir, 'names.txt'), 'w') as f:
        f.write('\n'.join(i['name'] for i in info) + '\n')
    with open(os.path.join(outdir, 'vectors.json'), 'w') as f:
        json.dump(dict(blocks=len(info), info=info), f, indent=1)
    print('%d blocks written to %s' % (len(info), outdir))
    print('worst |X - float reference| over bins 3..64, blocks without clipping: %.2f codes' % worst)
    for i in info:
        if i['name'].startswith(('event', 'tone', 'quiet')):
            print('  %-24s peak %2d band_ok %d decay %d sat %d' % (i['name'], i['peak'], i['band_ok'], i['decay'], i['sat']))


if __name__ == '__main__':
    main()
