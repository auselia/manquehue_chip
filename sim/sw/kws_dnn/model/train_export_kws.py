#!/usr/bin/env python3
"""
train_export_kws.py
-------------------
"Hey Croc" keyword spotting, same front-half flow as the MNIST example:

  Speech Commands -> MFCC features -> train DNN (FP32)
                  -> post-training static quantization (int8)
                  -> C header (kws_model.h) for the Croc kernels.

Model: DNN (Hello Edge, Zhang et al. arXiv:1711.07128) = stacked FC + ReLU,
       250 -> 32 -> 32 -> 12. Reuses nn_linear_u8_relu / nn_linear_out32
       unchanged -- identical machinery to MNIST.

Data : Google Speech Commands (Warden, arXiv:1804.03209) via torchaudio.

Quantization contract (see nn_linear.h), with ONE addition vs MNIST:
  MFCC inputs are SIGNED, so the input layer uses an asymmetric uint8 zero-point
  z_x. The correction (-z_x * sum_j W1[o][j]) is folded into the layer-1 bias,
  so the C kernel stays byte-identical. Hidden layers are ReLU (z = 0).

  activations uint8 ; weights int8 symmetric per-tensor ; bias int32 in acc domain
  layer1/2 requant: y = clamp_u8(round(acc * out_mult * 2^-out_shift))
  layer3:           raw int32 logits -> argmax

NOTE: this is a faithful-but-simplified data pipeline (silence/unknown handling
is approximate). For a publishable accuracy number use the official Speech
Commands splits / MLPerf Tiny KWS data prep. The printed int8 accuracy is what
runs on-chip.

Run locally (needs internet once):
  pip install torch torchaudio
  python train_export_kws.py
"""

import math
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio

# ---- config ---------------------------------------------------------------------
SR = 16000
N_MFCC = 10
N_FRAMES = 25
HOP = 640  # 40 ms
N_FFT = 640
N_MELS = 40
NUM_FEAT = N_MFCC * N_FRAMES  # 250
H1, H2 = 32, 32
EPOCHS = 12

LABELS = [
    "silence",
    "unknown",
    "yes",
    "no",
    "up",
    "down",
    "left",
    "right",
    "on",
    "off",
    "stop",
    "go",
]  # 12 classes, fixed order
KEYWORDS = {w: i for i, w in enumerate(LABELS) if w not in ("silence", "unknown")}
NUM_CLASS = len(LABELS)

mfcc = torchaudio.transforms.MFCC(
    sample_rate=SR, n_mfcc=N_MFCC, melkwargs={"n_fft": N_FFT, "hop_length": HOP, "n_mels": N_MELS}
)


def features(wav):
    # wav: [1, T] -> pad/clip to 1 s -> MFCC -> [N_MFCC, N_FRAMES] -> flat [250]
    if wav.shape[1] < SR:
        wav = F.pad(wav, (0, SR - wav.shape[1]))
    else:
        wav = wav[:, :SR]
    m = mfcc(wav).squeeze(0)  # [N_MFCC, time]
    if m.shape[1] < N_FRAMES:
        m = F.pad(m, (0, N_FRAMES - m.shape[1]))
    else:
        m = m[:, :N_FRAMES]
    return m.reshape(-1)  # [250]


# ---- dataset (simplified label mapping) -----------------------------------------
class KWSData(torch.utils.data.Dataset):
    def __init__(self, subset):
        self.ds = torchaudio.datasets.SPEECHCOMMANDS(".", download=True, subset=subset)

    def __len__(self):
        return len(self.ds)

    def __getitem__(self, i):
        wav, sr, label, *_ = self.ds[i]
        cls = KEYWORDS.get(label, 1)  # keyword -> its idx, else "unknown"=1
        # crude "silence": occasionally zero out a clip and relabel
        if (i % 11) == 0:
            wav = torch.zeros_like(wav)
            cls = 0
        return features(wav), cls


train = KWSData("training")
test = KWSData("testing")
trl = torch.utils.data.DataLoader(train, batch_size=128, shuffle=True)
tel = torch.utils.data.DataLoader(test, batch_size=256)


# ---- model ----------------------------------------------------------------------
class DNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(NUM_FEAT, H1)
        self.fc2 = nn.Linear(H1, H2)
        self.fc3 = nn.Linear(H2, NUM_CLASS)

    def forward(self, x):
        h1 = F.relu(self.fc1(x))
        h2 = F.relu(self.fc2(h1))
        return self.fc3(h2), h1, h2


net = DNN()
opt = torch.optim.Adam(net.parameters(), 1e-3)
for ep in range(EPOCHS):
    net.train()
    for xb, yb in trl:
        opt.zero_grad()
        out, _, _ = net(xb)
        F.cross_entropy(out, yb).backward()
        opt.step()
    net.eval()
    correct = n = 0
    with torch.no_grad():
        for xb, yb in tel:
            out, _, _ = net(xb)
            correct += (out.argmax(1) == yb).sum().item()
            n += len(yb)
    print(f"epoch {ep}: fp32 test acc {correct / n:.4f}")

# ---- observe ranges for PTQ -----------------------------------------------------
fmin = float("inf")
fmax = -float("inf")
h1max = h2max = 0.0
with torch.no_grad():
    for xb, _ in tel:
        out, h1, h2 = net(xb)
        fmin = min(fmin, xb.min().item())
        fmax = max(fmax, xb.max().item())
        h1max = max(h1max, h1.max().item())
        h2max = max(h2max, h2.max().item())

# input: asymmetric uint8 (signed MFCC) -> scale + zero-point
s_x = (fmax - fmin) / 255.0
z_x = int(round(-fmin / s_x))
z_x = max(0, min(255, z_x))
# hidden: ReLU outputs, zero-point 0
s_h1 = h1max / 255.0
s_h2 = h2max / 255.0


def wscale(w):
    return w.abs().max().item() / 127.0


W1 = net.fc1.weight.detach()
b1 = net.fc1.bias.detach()
W2 = net.fc2.weight.detach()
b2 = net.fc2.bias.detach()
W3 = net.fc3.weight.detach()
b3 = net.fc3.bias.detach()
s_w1, s_w2, s_w3 = wscale(W1), wscale(W2), wscale(W3)


def q_w(w, s):
    return torch.clamp(torch.round(w / s), -127, 127).to(torch.int8)


W1q, W2q, W3q = q_w(W1, s_w1), q_w(W2, s_w2), q_w(W3, s_w3)

# biases in accumulator domain; layer 1 also absorbs the input zero-point term
rowsum1 = W1q.to(torch.int32).sum(dim=1)  # sum_j W1[o][j]
b1q = torch.round(b1 / (s_x * s_w1)).to(torch.int32) - z_x * rowsum1
b2q = torch.round(b2 / (s_h1 * s_w2)).to(torch.int32)
b3q = torch.round(b3 / (s_h2 * s_w3)).to(torch.int32)


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


out_mult1, out_shift1 = fixed_point(s_x * s_w1 / s_h1)
out_mult2, out_shift2 = fixed_point(s_h1 * s_w2 / s_h2)


# ---- integer-only check: mirrors nn_linear.c (incl. input zero-point) -----------
def quant_in(x):
    return torch.clamp(torch.round(x / s_x) + z_x, 0, 255).to(torch.int32)


def requant(acc, m, sh):
    t = acc.to(torch.int64) * int(m)
    if sh > 0:
        t = (t + (1 << (sh - 1))) >> sh
    return torch.clamp(t, 0, 255).to(torch.int32)


correct = n = 0
with torch.no_grad():
    for xb, yb in tel:
        xq = quant_in(xb)
        a1 = xq @ W1q.to(torch.int32).T + b1q
        q1 = requant(a1, out_mult1, out_shift1)
        a2 = q1 @ W2q.to(torch.int32).T + b2q
        q2 = requant(a2, out_mult2, out_shift2)
        lg = q2 @ W3q.to(torch.int32).T + b3q
        correct += (lg.argmax(1) == yb).sum().item()
        n += len(yb)
print(f"int8 test acc {correct / n:.4f}   (this is the on-chip accuracy)")

# ---- pick one test sample to embed ----------------------------------------------
xb, yb = next(iter(tel))
feat0 = quant_in(xb[0]).to(torch.uint8).numpy()
lab0 = int(yb[0])


# ---- emit C header --------------------------------------------------------------
def carr(name, arr, ctype):
    flat = np.asarray(arr).reshape(-1).astype(np.int64).tolist()
    return f"static const {ctype} {name}[{len(flat)}] = {{{','.join(map(str, flat))}}};\n"


with open("../lib/inc/kws_model.h", "w") as f:
    f.write("// Auto-generated by train_export_kws.py -- do not edit by hand.\n")
    f.write(f"// int8 test accuracy at export time: {correct / n:.4f}\n")
    f.write("// Class order: " + " ".join(f"{i}:{w}" for i, w in enumerate(LABELS)) + "\n")
    f.write("#ifndef KWS_MODEL_H\n#define KWS_MODEL_H\n#include <stdint.h>\n\n")
    f.write(f"#define NUM_FEAT {NUM_FEAT}\n#define H1 {H1}\n#define H2 {H2}\n#define NUM_CLASS {NUM_CLASS}\n\n")
    f.write(carr("kws_W1", W1q.numpy(), "int8_t"))
    f.write(carr("kws_b1", b1q.numpy(), "int32_t"))
    f.write(carr("kws_W2", W2q.numpy(), "int8_t"))
    f.write(carr("kws_b2", b2q.numpy(), "int32_t"))
    f.write(carr("kws_W3", W3q.numpy(), "int8_t"))
    f.write(carr("kws_b3", b3q.numpy(), "int32_t"))
    f.write(f"static const int32_t kws_out_mult1 = {out_mult1};\nstatic const int kws_out_shift1 = {out_shift1};\n")
    f.write(f"static const int32_t kws_out_mult2 = {out_mult2};\nstatic const int kws_out_shift2 = {out_shift2};\n\n")
    f.write(carr("kws_test_feat", feat0, "uint8_t"))
    f.write(f"static const int kws_test_label = {lab0};\n")
    f.write("#endif\n")
print("wrote kws_model.h")
