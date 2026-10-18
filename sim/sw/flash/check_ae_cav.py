"""Check the RTL replay of ae_cav.c: packet and decision against the AE-FFT golden model on the same blocks.
usage: check_ae_cav.py <stream.hex> <wake index kw> <sim log>
The stream is the one given to tb_croc_soc with +adc_file (14-bit codes, one per line), kw the stream index of the
first sample at or after the WAKE_N edge (+adc_wake_frame = kw + 1). The script finds T in the stream from its first
word (printed by ae_cav.c), checks that P is the 128 samples before it, and recomputes the packet with the model."""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../fft/model'))
import aefft_model as m  # noqa: E402
hexf, kw, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CFG = m.default_cfg(gain_shift=3, en_shift=4, kmin=6, band_lo=22, band_hi=55, band_thr=179, decay_thr=192)
s = [int(l, 16) for l in open(hexf) if l.strip()]
s = [v - 0x4000 if v & 0x2000 else v for v in s]
L = open(log, errors='replace').read()
mt = re.search(r'UART\] T([0-9a-f]{8}) W([0-9a-f]{8}) P([0-9a-f]{8})', L)
mp = re.search(r'\[RF\] TX done, payload 24 bytes:((?: [0-9a-f]{2})+)', L)
cav = 'CAVITATION YES' in L
if not (mt and mp):
    print('FAIL: no tags or no packet in the log'); sys.exit(1)
def s16(v): return v - 0x10000 if v & 0x8000 else v
def pair(w): w = int(w, 16); return s16(w & 0xFFFF), s16(w >> 16)
t0, t1 = pair(mt.group(2)); p0, p1 = pair(mt.group(3))
ks = [k for k in range(len(s) - 1) if s[k] == t0 and s[k + 1] == t1]
if len(ks) != 1:
    print('FAIL: T found %d times in the stream' % len(ks)); sys.exit(1)
k = ks[0]
p_ok = s[k - 128] == p0 and s[k - 127] == p1
st = dict(td_prev=0, prev_valid=0)
r1 = m.run_block(s[k:k + 128], CFG, st); r2 = m.run_block(s[k - 128:k], CFG, st)
p = bytes(int(x, 16) for x in mp.group(1).split())
u = lambda i: int.from_bytes(p[i:i + 4], 'little')
exp = dict(magic=ord('C'), flags=r1['band_ok'] | r2['decay'] << 1 | (r1['sat'] | r2['sat']) << 2, peak=r1['peak'],
           ppow=r1['peak_pow'], band=r1['band'], total=r1['total'], tdT=r1['td'], tdP=r2['td'], cav=r1['band_ok'] & r2['decay'])
got = dict(magic=p[0], flags=p[2] & 7, peak=p[3], ppow=u(4), band=u(8), total=u(12), tdT=u(16), tdP=u(20), cav=int(cav))
ok = p_ok and exp == got
print(f'trigger position o = {kw - k:3d}, P is the 128 samples before T: {p_ok}, packet {p.hex()}')
print(f'  peak bin {got["peak"]} = {got["peak"] * 909.09 / 128:.1f} kHz, band/total {got["band"] / max(got["total"], 1):.3f}, '
      f'TD P/T {got["tdP"] / max(got["tdT"], 1):.3f}, flags BAND_OK {got["flags"] & 1} DECAY {got["flags"] >> 1 & 1} SAT {got["flags"] >> 2 & 1}, '
      f'CAVITATION {"YES" if cav else "NO"}: ' + ('matches the model' if ok else f'MISMATCH model {exp} got {got}'))
sys.exit(0 if ok else 1)
