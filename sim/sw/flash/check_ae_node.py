#!/usr/bin/env python3
"""Check the LoRa packets of sim/sw/flash/ae_node.c against the golden model of the AE-FFT.

usage: check_ae_node.py <simulation log> [tone bin, default 36]

The log has one "[RF] TX done, payload 24 bytes: .." line per packet (rtl/test/tb_croc_soc.sv). The testbench
stimulus with +adc_tone=<b> is code(k) = round(3000 sin(2 pi b k / 128)) + ((1237 k) mod 61) - 30, 14-bit two's
complement. Bytes 4..7 of a packet are the first two samples of the block. The script finds k where code(k) and
code(k+1) are these two samples, runs sim/fft/model/aefft_model.run_block on code(k..k+127) with the configuration
of ae_node.c, and compares PEAK_BIN, the status bits and the four energies. The sequence repeats every 1,952
samples, so every k that matches gives the same block.
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../fft/model'))
import aefft_model as m  # noqa: E402

log, tone = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 36
CFG = m.default_cfg(gain_shift=2, en_shift=4, kmin=3, band_lo=32, band_hi=39, band_thr=179, decay_thr=192)


def code(k):
    v = 3000.0 * math.sin(2.0 * 3.141592653589793 * tone * k / 128.0)
    c = int(v + 0.5) if v >= 0.0 else int(v - 0.5)
    c = (c + (k * 1237) % 61 - 30) & 0x3FFF
    return c - 0x4000 if c & 0x2000 else c


SEQ = [code(k) for k in range(4096)]
pkts = []
for line in open(log, errors='replace'):
    mm = re.search(r'\[RF\] TX done, payload (\d+) bytes:((?: [0-9a-f]{2})+)', line)
    if mm:
        pkts.append(bytes(int(x, 16) for x in mm.group(2).split()))

def u32(p, i):
    return int.from_bytes(p[i:i + 4], 'little')

def s16(v):
    return v - 0x10000 if v & 0x8000 else v

state = dict(td_prev=0, prev_valid=0)
bad = 0
for p in pkts:
    if len(p) != 24 or p[0] != ord('A'):
        print('packet with the wrong format:', p.hex()); bad += 1; continue
    seq, peak, flags = p[1], p[2], p[3]
    s0, s1 = s16(u32(p, 4) & 0xFFFF), s16(u32(p, 4) >> 16)
    ks = [k for k in range(1952) if SEQ[k] == s0 and SEQ[k + 1] == s1]
    if not ks:
        print(f'block {seq}: samples {s0} {s1} are not in the stimulus'); bad += 1; continue
    if seq == 0:
        state = dict(td_prev=0, prev_valid=0)               # CLR_PREV on the first block
    r = m.run_block(SEQ[ks[0]:ks[0] + 128], CFG, state)
    exp = dict(peak=r['peak'], flags=m.status_bits(r) >> 2, peak_pow=r['peak_pow'], band=r['band'],
               total=r['total'], td=r['td'])
    got = dict(peak=peak, flags=flags, peak_pow=u32(p, 8), band=u32(p, 12), total=u32(p, 16), td=u32(p, 20))
    ok = exp == got
    bad += not ok
    print(f'block {seq}: start k = {ks[0]} (mod 1952), peak bin {peak}, flags {flags:04b}, '
          f'peak_pow {got["peak_pow"]}, band {got["band"]}, total {got["total"]}, td {got["td"]}: '
          + ('matches the model' if ok else f'MISMATCH, model {exp}'))
print(f'{len(pkts)} packets, {bad} wrong' + ('' if pkts else ' (no packets)'))
print('PASS' if pkts and not bad else 'FAIL')
sys.exit(0 if pkts and not bad else 1)
