#!/usr/bin/env python3
"""
train_export_mnist.py
---------------------
Front half of the PULP/NEMO flow, done with plain PyTorch (no NEMO dependency):

  train FP32  ->  post-training static quantization (per-tensor)
              ->  integer weights/bias + fixed-point requant params
              ->  C header (mnist_model.h) for the Croc kernels.

The integer math below is byte-for-byte what nn_linear.c computes, so the
"int8 test acc" printed here is the accuracy you will get on-chip.

Quantization contract (see nn_linear.h):
  activations uint8, zero-point = 0 (inputs in [0,1], hidden = ReLU >= 0)
  weights     int8,  symmetric (zero-point = 0), per-tensor
  bias        int32 in the accumulator domain  b/(s_x*s_w)
  layer-1 requant:  y = clamp_u8( round(acc * out_mult * 2^-out_shift) )
  layer-2:          raw int32 logits -> argmax (no requant needed)

Run locally (needs internet once to fetch MNIST):
  pip install torch torchvision
  python train_export_mnist.py
"""

import math
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms

DIM_IN, DIM_H, DIM_OUT = 196, 32, 10  # 14x14 -> 32 -> 10
EPOCHS = 8


# ---- data: 28x28 -> 14x14 via 2x2 average pool, kept in [0,1] -------------------
def to_vec(img):
    x = transforms.functional.to_tensor(img)  # [1,28,28] in [0,1]
    x = F.avg_pool2d(x.unsqueeze(0), 2).squeeze(0)  # [1,14,14]
    return x.reshape(-1)  # [196]


tf = transforms.Lambda(to_vec)
train = datasets.MNIST(".", train=True, download=True, transform=tf)
test = datasets.MNIST(".", train=False, download=True, transform=tf)
trl = torch.utils.data.DataLoader(train, batch_size=128, shuffle=True)
tel = torch.utils.data.DataLoader(test, batch_size=256)


# ---- model ----------------------------------------------------------------------
class MLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(DIM_IN, DIM_H)
        self.fc2 = nn.Linear(DIM_H, DIM_OUT)

    def forward(self, x):
        h = F.relu(self.fc1(x))
        return self.fc2(h), h


net = MLP()
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

# ---- observe activation ranges (per-tensor, zero-point = 0) ---------------------
xmax = hmax = 0.0
with torch.no_grad():
    for xb, _ in tel:
        out, h = net(xb)
        xmax = max(xmax, xb.max().item())
        hmax = max(hmax, h.max().item())
s_x = xmax / 255.0
s_h = hmax / 255.0


# ---- weight quantization (symmetric int8, per-tensor) ---------------------------
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
b1q = torch.round(b1 / (s_x * s_w1)).to(torch.int32)
b2q = torch.round(b2 / (s_h * s_w2)).to(torch.int32)


# ---- fixed-point requant multiplier for layer 1 (TFLite-style M = m0 * 2^exp) ---
def fixed_point(M, mant_bits=30):
    if M <= 0:
        return 0, 0
    m0, exp = math.frexp(M)  # m0 in [0.5,1), M = m0 * 2^exp
    out_mult = int(round(m0 * (1 << mant_bits)))
    out_shift = mant_bits - exp
    if out_shift < 0:  # M >= 1 fallback
        out_mult >>= -out_shift
        out_shift = 0
    return out_mult, out_shift


M1 = s_x * s_w1 / s_h
out_mult1, out_shift1 = fixed_point(M1)


# ---- integer-only check: this mirrors nn_linear.c exactly -----------------------
def quant_act(x, s):
    return torch.clamp(torch.round(x / s), 0, 255).to(torch.int32)


def requant(acc, m, sh):
    t = acc.to(torch.int64) * int(m)
    if sh > 0:
        t = (t + (1 << (sh - 1))) >> sh
    return torch.clamp(t, 0, 255).to(torch.int32)


correct = n = 0
with torch.no_grad():
    for xb, yb in tel:
        xq = quant_act(xb, s_x)  # [B,196]
        acc1 = xq @ W1q.to(torch.int32).T + b1q  # [B,32]
        hq = requant(acc1, out_mult1, out_shift1)  # uint8 domain
        logits = hq @ W2q.to(torch.int32).T + b2q  # [B,10]
        correct += (logits.argmax(1) == yb).sum().item()
        n += len(yb)
print(f"int8 test acc {correct / n:.4f}   (this is the on-chip accuracy)")

# ---- pick one test sample to embed for the on-chip demo -------------------------
xb, yb = next(iter(tel))
img0 = quant_act(xb[0], s_x).to(torch.uint8).numpy()
lab0 = int(yb[0])


# ---- emit C header --------------------------------------------------------------
def carr(name, arr, ctype):
    flat = np.asarray(arr).reshape(-1).astype(np.int64).tolist()
    return f"static const {ctype} {name}[{len(flat)}] = {{{','.join(map(str, flat))}}};\n"


with open("../lib/inc/mnist_model.h", "w") as f:
    f.write("// Auto-generated by train_export_mnist.py -- do not edit by hand.\n")
    f.write(f"// int8 test accuracy at export time: {correct / n:.4f}\n")
    f.write("#ifndef MNIST_MODEL_H\n#define MNIST_MODEL_H\n#include <stdint.h>\n\n")
    f.write(f"#define DIM_IN {DIM_IN}\n#define DIM_H {DIM_H}\n#define DIM_OUT {DIM_OUT}\n\n")
    f.write(carr("mnist_W1", W1q.numpy(), "int8_t"))  # [DIM_H][DIM_IN] row-major
    f.write(carr("mnist_b1", b1q.numpy(), "int32_t"))
    f.write(carr("mnist_W2", W2q.numpy(), "int8_t"))  # [DIM_OUT][DIM_H]
    f.write(carr("mnist_b2", b2q.numpy(), "int32_t"))
    f.write(f"static const int32_t mnist_out_mult1 = {out_mult1};\n")
    f.write(f"static const int     mnist_out_shift1 = {out_shift1};\n\n")
    f.write(carr("mnist_test_image", img0, "uint8_t"))
    f.write(f"static const int mnist_test_label = {lab0};\n")
    f.write("#endif\n")
print("wrote mnist_model.h")
