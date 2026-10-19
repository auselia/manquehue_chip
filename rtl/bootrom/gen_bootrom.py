#!/usr/bin/env python3
# Regenerate the ROM tables of bootrom.sv from bootrom.S.
# Assembles bootrom.S at 0x0200_0000 (rv32i, no compressed instructions, so every instruction is one ROM word),
# disassembles it and rewrites the four contiguous blocks (_start, _eoc, _trap_handler_wrapper, _trap_exit) of
# bootrom.sv, with the disassembly as comments.
# usage: rtl/bootrom/gen_bootrom.py        RISCV_PREFIX (default riscv32-none-elf-)
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PFX = os.environ.get("RISCV_PREFIX", "riscv32-none-elf-")
BLOCKS = [("_start", "StartRom"), ("_eoc", "EocRom"),
          ("_trap_handler_wrapper", "TrapHandlerRom"), ("_trap_exit", "TrapExitRom")]

def run(*cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if r.returncode != 0:
        sys.exit(" ".join(cmd) + "\n" + r.stdout)
    return r.stdout

with tempfile.TemporaryDirectory() as d:
    elf = os.path.join(d, "bootrom.elf")
    run(PFX + "gcc", "-march=rv32i_zicsr", "-mabi=ilp32", "-nostdlib", "-nostartfiles",
        "-Wl,-Ttext=0x02000000", "-Wl,--no-relax", "-o", elf, os.path.join(HERE, "bootrom.S"))
    dump = run(PFX + "objdump", "-d", elf)

# addr -> (word, text), and label -> address
words, labels = {}, {}
for line in dump.splitlines():
    m = re.match(r"^([0-9a-f]{8}) <([^>]+)>:", line)
    if m:
        labels[m.group(2)] = int(m.group(1), 16)
        continue
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$", line)
    if m:
        words[int(m.group(1), 16)] = (int(m.group(2), 16), re.sub(r"\s+", " ", m.group(3)).strip())

sv_path = os.path.join(HERE, "bootrom.sv")
sv = open(sv_path).read()
for label, name in BLOCKS:
    a = labels[label]
    body = []
    while a in words:
        w, txt = words[a]
        body.append((a, w, txt))
        a += 4
    lines = [f"        // <{label}>"]
    for i, (addr, w, txt) in enumerate(body):
        sep = "," if i < len(body) - 1 else ""
        lines.append(f"        32'h{w:08X}{sep} // 0x{addr:08X}: {txt}")
    pat = re.compile(r"(localparam int unsigned " + name + r"Words = )\d+;(\s*localparam logic \[31:0\] " + name +
                     r" \[" + name + r"Words\] = '\{\n).*?(\n    \};)", re.S)
    if not pat.search(sv):
        sys.exit(f"block {name} not found in bootrom.sv")
    sv = pat.sub(lambda m: m.group(1) + str(len(body)) + ";" + m.group(2) + "\n".join(lines) + m.group(3), sv, count=1)
    print(f"{name}: {len(body)} words at 0x{labels[label]:08X}")
open(sv_path, "w").write(sv)
