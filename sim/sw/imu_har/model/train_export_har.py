#!/usr/bin/env python3
"""
train_export_har.py
-------------------
IMU human-activity recognition, same front-half flow as the other examples.

  UCI HAR raw inertial signals -> downsample window -> train MLP (FP32)
                               -> post-training int8 quantization
                               -> C header (har_model.h) for the Croc kernels.

Model: MLP 288 -> 32 -> 6, reusing nn_linear_u8_relu / nn_linear_out32 unchanged.
Data : UCI HAR Dataset (Anguita et al., 2013), "Inertial Signals" (raw),
       9 channels x 128 samples per 2.56 s window @ 50 Hz, downsampled to
       32 timesteps -> flattened time-major (t*9 + c) = 288 features.

NOTE on modeling: flattening a raw window into an MLP ignores temporal
structure -- this is a legitimate small *baseline*. A 1D-CNN is the better
model and drops straight into the existing conv kernels (use nn_conv2d with
W = 1, KW = 1, treating the window as [T][1][C]).

Quantization contract (see nn_linear.h): IMU samples are signed, so the input
layer uses an asymmetric uint8 zero-point z_x; the correction is folded into the
layer-1 bias (kernel stays byte-identical). Hidden layer is ReLU (z = 0).

Setup (needs the dataset once):
  # download + unzip "UCI HAR Dataset" from the UCI ML repository, then:
  pip install torch numpy
  python train_export_har.py            # set DATA_DIR below if needed
"""

import math
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

DATA_DIR = "UCI HAR Dataset"  # path to the unzipped dataset
T_RAW = 128
T_DS = 32  # downsampled timesteps (mean-pool by 4)
N_CH = 9
NUM_FEAT = T_DS * N_CH  # 288
H = 32
NUM_CLASS = 6
EPOCHS = 30

SIGNALS = [
    "body_acc_x",
    "body_acc_y",
    "body_acc_z",
    "body_gyro_x",
    "body_gyro_y",
    "body_gyro_z",
    "total_acc_x",
    "total_acc_y",
    "total_acc_z",
]


def load_split(split):
    # returns X [N, T_DS, N_CH] float, y [N] int in 0..5
    sigs = []
    for s in SIGNALS:
        path = f"{DATA_DIR}/{split}/Inertial Signals/{s}_{split}.txt"
        sigs.append(np.loadtxt(path))  # [N, 128]
    X = np.stack(sigs, axis=-1)  # [N, 128, 9]
    # mean-pool time 128 -> 32
    X = X.reshape(X.shape[0], T_DS, T_RAW // T_DS, N_CH).mean(axis=2)  # [N,32,9]
    y = np.loadtxt(f"{DATA_DIR}/{split}/y_{split}.txt").astype(int) - 1  # 1..6 -> 0..5
    return X.astype(np.float32), y


Xtr, ytr = load_split("train")
Xte, yte = load_split("test")

# flatten time-major: feature index = t*N_CH + c  (matches har_infer.c)
Xtr = torch.tensor(Xtr.reshape(len(Xtr), -1))
Xte = torch.tensor(Xte.reshape(len(Xte), -1))
ytr = torch.tensor(ytr)
yte = torch.tensor(yte)


class MLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(NUM_FEAT, H)
        self.fc2 = nn.Linear(H, NUM_CLASS)

    def forward(self, x):
        h = F.relu(self.fc1(x))
        return self.fc2(h), h


net = MLP()
opt = torch.optim.Adam(net.parameters(), 1e-3)
trl = torch.utils.data.DataLoader(torch.utils.data.TensorDataset(Xtr, ytr), batch_size=64, shuffle=True)
for ep in range(EPOCHS):
    net.train()
    for xb, yb in trl:
        opt.zero_grad()
        out, _ = net(xb)
        F.cross_entropy(out, yb).backward()
        opt.step()
    net.eval()
    with torch.no_grad():
        acc = (net(Xte)[0].argmax(1) == yte).float().mean().item()
    print(f"epoch {ep}: fp32 test acc {acc:.4f}")

# ---- PTQ ------------------------------------------------------------------------
with torch.no_grad():
    _, hidden = net(Xte)
fmin, fmax = Xtr.min().item(), Xtr.max().item()
hmax = hidden.max().item()
s_x = (fmax - fmin) / 255.0
z_x = max(0, min(255, int(round(-fmin / s_x))))
s_h = hmax / 255.0


def wscale(w):
    return w.abs().max().item() / 127.0


W1 = net.fc1.weight.detach()
b1 = net.fc1.bias.detach()
W2 = net.fc2.weight.detach()
b2 = net.fc2.bias.detach()
s_w1, s_w2 = wscale(W1), wscale(W2)


def q_w(w, s):
    return torch.clamp(torch.round(w / s), -127, 127).to(torch.int8)


W1q, W2q = q_w(W1, s_w1), q_w(W2, s_w2)
b1q = torch.round(b1 / (s_x * s_w1)).to(torch.int32) - z_x * W1q.to(torch.int32).sum(dim=1)
b2q = torch.round(b2 / (s_h * s_w2)).to(torch.int32)


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


out_mult1, out_shift1 = fixed_point(s_x * s_w1 / s_h)


# ---- integer check (mirrors nn_linear.c, incl. input zero-point) ----------------
def quant_in(x):
    return torch.clamp(torch.round(x / s_x) + z_x, 0, 255).to(torch.int32)


def requant(acc, m, sh):
    t = acc.to(torch.int64) * int(m)
    if sh > 0:
        t = (t + (1 << (sh - 1))) >> sh
    return torch.clamp(t, 0, 255).to(torch.int32)


with torch.no_grad():
    xq = quant_in(Xte)
    a1 = xq @ W1q.to(torch.int32).T + b1q
    q1 = requant(a1, out_mult1, out_shift1)
    lg = q1 @ W2q.to(torch.int32).T + b2q
    acc = (lg.argmax(1) == yte).float().mean().item()
print(f"int8 test acc {acc:.4f}   (this is the on-chip accuracy)")

# ---- pick a test sample and emit ------------------------------------------------
feat0 = quant_in(Xte[0]).to(torch.uint8).numpy()
lab0 = int(yte[0])


def carr(name, arr, ctype):
    flat = np.asarray(arr).reshape(-1).astype(np.int64).tolist()
    return f"static const {ctype} {name}[{len(flat)}] = {{{','.join(map(str, flat))}}};\n"


with open("har_model.h", "w") as f:
    f.write("// Auto-generated by train_export_har.py -- do not edit by hand.\n")
    f.write(f"// int8 test accuracy at export time: {acc:.4f}\n")
    f.write("// Class order: 0 walking 1 upstairs 2 downstairs 3 sitting 4 standing 5 laying\n")
    f.write("// Input: 32 timesteps x 9 channels, flattened time-major (t*9 + c).\n")
    f.write("#ifndef HAR_MODEL_H\n#define HAR_MODEL_H\n#include <stdint.h>\n\n")
    f.write(f"#define NUM_FEAT {NUM_FEAT}\n#define H {H}\n#define NUM_CLASS {NUM_CLASS}\n\n")
    f.write(carr("har_W1", W1q.numpy(), "int8_t"))
    f.write(carr("har_b1", b1q.numpy(), "int32_t"))
    f.write(carr("har_W2", W2q.numpy(), "int8_t"))
    f.write(carr("har_b2", b2q.numpy(), "int32_t"))
    f.write(f"static const int32_t har_out_mult1 = {out_mult1};\nstatic const int har_out_shift1 = {out_shift1};\n\n")
    f.write(carr("har_test_feat", feat0, "uint8_t"))
    f.write(f"static const int har_test_label = {lab0};\n")
    f.write("#endif\n")
print("wrote har_model.h")
