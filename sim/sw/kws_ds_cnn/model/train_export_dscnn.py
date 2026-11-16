#!/usr/bin/env python3
"""
train_export_dscnn.py
---------------------
Reduced DS-CNN keyword spotter for Croc, same front-half flow as the others.

  Speech Commands -> MFCC [T,F] (as 1-channel image) -> train DS-CNN (FP32)
                  -> post-training int8 quantization -> C header (dscnn_model.h).

Architecture (reduced from Hello Edge / MLPerf Tiny DS-CNN so it fits 16 KB):
  conv1 : Conv2d(1, C, 3x3, stride 2, VALID)        + ReLU
  block : depthwise 3x3 (pad 1) + ReLU, pointwise 1x1 + ReLU      (x2)
  head  : global avg pool -> Linear(C, NUM_CLASS)

No BatchNorm (keeps the per-tensor quant identical to the FC examples; folding
BN is the obvious accuracy improvement later).

Quantization contract (see nn_conv.h / nn_linear.h):
  uint8 activations (zero-point 0 on ReLU outputs) ; int8 symmetric weights ;
  int32 bias in accumulator domain ; per-tensor requant with ReLU clamp.
  Input MFCC is signed -> asymmetric uint8 zero-point z_x; its correction is
  folded into conv1's bias, and conv1 is VALID so padding never sees z_x.
  Depthwise pads with 0 (correct: its inputs are ReLU, zero-point 0).

Weights are transposed from PyTorch NCHW to the kernels' HWC layout on export.

Run locally (needs internet once):
  pip install torch torchaudio
  python train_export_dscnn.py
"""

import math
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio

# ---- config (must match dscnn_model.h / dscnn_infer.c) --------------------------
SR, N_MFCC, N_FRAMES, HOP, N_FFT, N_MELS = 16000, 10, 25, 640, 640, 40
IN_T, IN_F = N_FRAMES, N_MFCC  # MFCC as a [T,F] single-channel image
C = 16
EPOCHS = 15
LABELS = ["silence", "unknown", "yes", "no", "up", "down", "left", "right", "on", "off", "stop", "go"]
KEYWORDS = {w: i for i, w in enumerate(LABELS) if w not in ("silence", "unknown")}
NUM_CLASS = len(LABELS)

mfcc = torchaudio.transforms.MFCC(
    sample_rate=SR, n_mfcc=N_MFCC, melkwargs={"n_fft": N_FFT, "hop_length": HOP, "n_mels": N_MELS}
)


def features(wav):
    if wav.shape[1] < SR:
        wav = F.pad(wav, (0, SR - wav.shape[1]))
    else:
        wav = wav[:, :SR]
    m = mfcc(wav).squeeze(0)  # [N_MFCC, time]
    if m.shape[1] < N_FRAMES:
        m = F.pad(m, (0, N_FRAMES - m.shape[1]))
    else:
        m = m[:, :N_FRAMES]
    return m[:, :N_FRAMES].T.contiguous()  # [T, F]


class KWSData(torch.utils.data.Dataset):
    def __init__(self, subset):
        self.ds = torchaudio.datasets.SPEECHCOMMANDS(".", download=True, subset=subset)

    def __len__(self):
        return len(self.ds)

    def __getitem__(self, i):
        wav, sr, label, *_ = self.ds[i]
        cls = KEYWORDS.get(label, 1)
        if (i % 11) == 0:
            wav = torch.zeros_like(wav)
            cls = 0
        return features(wav).unsqueeze(0), cls  # [1, T, F]


train = KWSData("training")
test = KWSData("testing")
trl = torch.utils.data.DataLoader(train, batch_size=128, shuffle=True)
tel = torch.utils.data.DataLoader(test, batch_size=256)


# ---- model ----------------------------------------------------------------------
class DSCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, C, 3, stride=2)  # valid
        self.dw1 = nn.Conv2d(C, C, 3, padding=1, groups=C)
        self.pw1 = nn.Conv2d(C, C, 1)
        self.dw2 = nn.Conv2d(C, C, 3, padding=1, groups=C)
        self.pw2 = nn.Conv2d(C, C, 1)
        self.fc = nn.Linear(C, NUM_CLASS)

    def forward(self, x):
        a = {}
        x = F.relu(self.conv1(x))
        a["c1"] = x
        x = F.relu(self.dw1(x))
        a["d1"] = x
        x = F.relu(self.pw1(x))
        a["p1"] = x
        x = F.relu(self.dw2(x))
        a["d2"] = x
        x = F.relu(self.pw2(x))
        a["p2"] = x
        g = x.mean(dim=(2, 3))
        a["g"] = g
        return self.fc(g), a


net = DSCNN()
opt = torch.optim.Adam(net.parameters(), 1e-3)
for ep in range(EPOCHS):
    net.train()
    for xb, yb in trl:
        opt.zero_grad()
        out, _ = net(xb)
        F.cross_entropy(out, yb).backward()
        opt.step()
    net.eval()
    correct = n = 0
    with torch.no_grad():
        for xb, yb in tel:
            out, _ = net(xb)
            correct += (out.argmax(1) == yb).sum().item()
            n += len(yb)
    print(f"epoch {ep}: fp32 test acc {correct / n:.4f}")

# ---- observe ranges (per-tensor) ------------------------------------------------
ranges = {k: [float("inf"), -float("inf")] for k in ["in", "c1", "d1", "p1", "d2", "p2", "g"]}
with torch.no_grad():
    for xb, _ in tel:
        out, a = net(xb)
        ranges["in"][0] = min(ranges["in"][0], xb.min().item())
        ranges["in"][1] = max(ranges["in"][1], xb.max().item())
        for k in ["c1", "d1", "p1", "d2", "p2", "g"]:
            ranges[k][1] = max(ranges[k][1], a[k].max().item())

s_x = (ranges["in"][1] - ranges["in"][0]) / 255.0
z_x = max(0, min(255, int(round(-ranges["in"][0] / s_x))))
s_c1 = ranges["c1"][1] / 255.0
s_d1 = ranges["d1"][1] / 255.0
s_p1 = ranges["p1"][1] / 255.0
s_d2 = ranges["d2"][1] / 255.0
s_p2 = ranges["p2"][1] / 255.0
s_g = s_p2  # global avg pool preserves scale


def wscale(w):
    return w.abs().max().item() / 127.0


def q_w(w, s):
    return torch.clamp(torch.round(w / s), -127, 127).to(torch.int8)


s_w = {n: wscale(getattr(net, n).weight.detach()) for n in ["conv1", "dw1", "pw1", "dw2", "pw2", "fc"]}
qw = {n: q_w(getattr(net, n).weight.detach(), s_w[n]) for n in ["conv1", "dw1", "pw1", "dw2", "pw2", "fc"]}


def fixed_point(M, mant_bits=30):
    if M <= 0:
        return 0, 0
    m0, exp = math.frexp(M)
    om = int(round(m0 * (1 << mant_bits)))
    sh = mant_bits - exp
    if sh < 0:
        om >>= -sh
        sh = 0
    return om, sh


mult, shift = {}, {}
for nm, sin, sout in [
    ("conv1", s_x, s_c1),
    ("dw1", s_c1, s_d1),
    ("pw1", s_d1, s_p1),
    ("dw2", s_p1, s_d2),
    ("pw2", s_d2, s_p2),
]:
    mult[nm], shift[nm] = fixed_point(sin * s_w[nm] / sout)


# biases in accumulator domain
def bias_int(n, sin):
    b = getattr(net, n).bias.detach()
    return torch.round(b / (sin * s_w[n])).to(torch.int32)


b = {
    "conv1": bias_int("conv1", s_x),
    "dw1": bias_int("dw1", s_c1),
    "pw1": bias_int("pw1", s_d1),
    "dw2": bias_int("dw2", s_p1),
    "pw2": bias_int("pw2", s_d2),
    "fc": bias_int("fc", s_g),
}
# conv1 absorbs the input zero-point: -z_x * sum over each filter
b["conv1"] = b["conv1"] - z_x * qw["conv1"].to(torch.int32).sum(dim=(1, 2, 3))


# ---- integer-only check (mirrors the C kernels via F.conv2d on int tensors) -----
def rq(acc, m, sh):
    t = acc.to(torch.int64) * int(m)
    if sh > 0:
        t = (t + (1 << (sh - 1))) >> sh
    return torch.clamp(t, 0, 255).to(torch.int32)


correct = n = 0
with torch.no_grad():
    for xb, yb in tel:
        xq = torch.clamp(torch.round(xb / s_x) + z_x, 0, 255)
        x = F.conv2d(xq, qw["conv1"].float(), stride=2) + b["conv1"].view(1, -1, 1, 1)
        x = rq(x, mult["conv1"], shift["conv1"]).float()
        x = F.conv2d(x, qw["dw1"].float(), padding=1, groups=C) + b["dw1"].view(1, -1, 1, 1)
        x = rq(x, mult["dw1"], shift["dw1"]).float()
        x = F.conv2d(x, qw["pw1"].float()) + b["pw1"].view(1, -1, 1, 1)
        x = rq(x, mult["pw1"], shift["pw1"]).float()
        x = F.conv2d(x, qw["dw2"].float(), padding=1, groups=C) + b["dw2"].view(1, -1, 1, 1)
        x = rq(x, mult["dw2"], shift["dw2"]).float()
        x = F.conv2d(x, qw["pw2"].float()) + b["pw2"].view(1, -1, 1, 1)
        x = rq(x, mult["pw2"], shift["pw2"]).float()
        g = torch.round(x.mean(dim=(2, 3)))  # global avg (uint8 domain)
        lg = g @ qw["fc"].to(torch.float).T + b["fc"].float()
        correct += (lg.argmax(1) == yb).sum().item()
        n += len(yb)
print(f"int8 test acc {correct / n:.4f}   (this is the on-chip accuracy)")


# ---- transpose NCHW -> HWC for the kernels & emit -------------------------------
def carr(name, arr, ctype):
    flat = np.asarray(arr).reshape(-1).astype(np.int64).tolist()
    return f"static const {ctype} {name}[{len(flat)}] = {{{','.join(map(str, flat))}}};\n"


# conv1 [C,1,3,3] -> [C,3,3,1] (co,kh,kw,ci)
conv1_hwc = qw["conv1"].permute(0, 2, 3, 1).contiguous().numpy()
# depthwise [C,1,3,3] -> [C,3,3]
dw1_hwc = qw["dw1"].squeeze(1).contiguous().numpy()
dw2_hwc = qw["dw2"].squeeze(1).contiguous().numpy()
# pointwise [Cout,Cin,1,1] -> [Cout,Cin]
pw1_hwc = qw["pw1"].squeeze(-1).squeeze(-1).contiguous().numpy()
pw2_hwc = qw["pw2"].squeeze(-1).squeeze(-1).contiguous().numpy()
fc_w = qw["fc"].numpy()  # [NUM_CLASS, C]

xb, yb = next(iter(tel))
feat0 = torch.clamp(torch.round(xb[0] / s_x) + z_x, 0, 255).to(torch.uint8)
feat0 = feat0.squeeze(0).numpy()  # [T, F] -> HWC flatten (C=1)
lab0 = int(yb[0])

with open("../lib/inc/dscnn_model.h", "w") as f:
    f.write("// Auto-generated by train_export_dscnn.py -- do not edit by hand.\n")
    f.write(f"// int8 test accuracy at export time: {correct / n:.4f}\n")
    f.write("// Class order: " + " ".join(f"{i}:{w}" for i, w in enumerate(LABELS)) + "\n")
    f.write("#ifndef DSCNN_MODEL_H\n#define DSCNN_MODEL_H\n#include <stdint.h>\n\n")
    f.write(
        f"#define IN_T {IN_T}\n#define IN_F {IN_F}\n#define IN_C 1\n#define DS_C {C}\n#define NUM_CLASS {NUM_CLASS}\n"
    )
    f.write(f"#define C1_H {(IN_T - 3) // 2 + 1}\n#define C1_W {(IN_F - 3) // 2 + 1}\n\n")
    f.write(carr("ds_conv1_w", conv1_hwc, "int8_t"))
    f.write(carr("ds_conv1_b", b["conv1"].numpy(), "int32_t"))
    f.write(carr("ds_dw1_w", dw1_hwc, "int8_t"))
    f.write(carr("ds_dw1_b", b["dw1"].numpy(), "int32_t"))
    f.write(carr("ds_pw1_w", pw1_hwc, "int8_t"))
    f.write(carr("ds_pw1_b", b["pw1"].numpy(), "int32_t"))
    f.write(carr("ds_dw2_w", dw2_hwc, "int8_t"))
    f.write(carr("ds_dw2_b", b["dw2"].numpy(), "int32_t"))
    f.write(carr("ds_pw2_w", pw2_hwc, "int8_t"))
    f.write(carr("ds_pw2_b", b["pw2"].numpy(), "int32_t"))
    f.write(carr("ds_fc_w", fc_w, "int8_t"))
    f.write(carr("ds_fc_b", b["fc"].numpy(), "int32_t"))
    for nm in ["conv1", "dw1", "pw1", "dw2", "pw2"]:
        f.write(f"static const int32_t ds_{nm}_mult = {mult[nm]};\nstatic const int ds_{nm}_shift = {shift[nm]};\n")
    f.write("\n")
    f.write(carr("ds_test_feat", feat0, "uint8_t"))
    f.write(f"static const int ds_test_label = {lab0};\n")
    f.write("#endif\n")
print("wrote dscnn_model.h")
