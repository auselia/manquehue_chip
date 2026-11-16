#!/usr/bin/env python3
# Simulation copies of the PDK cell models, the SRAM model, the netlist and the program, for the gate-level checks
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: gate_models.py cells <cells.v> <out> [--no-keeper] [--flop-delay <delay>] [--timescale]
#        gate_models.py primitives <primitives.v> <out> [--init 0|1] [--timescale]
#        gate_models.py sram <sram.v> <out>
#        gate_models.py netlist <croc_soc.v> <out> (--no-supply-ports | --no-comments)
#        gate_models.py words <program.hex> <out>
# in:  the PDK Verilog models, the netlist of a run, a program .hex (objcopy -O verilog)
# out: the patched copy. The originals do not change.
import argparse
import re

CELL_PREFIX = "gf180mcu_fd_sc_mcu7t5v0"
# Without a timescale, Icarus uses 1 s units and rounds the flop delay to 0
TIMESCALE = "`timescale 1ns/1ps\n"


def read(path):
    with open(path) as f:
        return f.read()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def cells(args):
    """The cell models. --no-keeper: plain buffers (Verilator cannot model the weak bus keeper).
    --flop-delay: a buffer with this delay on the output of every sequential UDP. With zero delay the clock tree
    races: the JTAG TAP shifts one cycle early. The delay stays above the 100 ps at which the SRAM model samples
    its inputs after the clock, or stores are corrupted."""
    text = read(args.src)
    if args.no_keeper:
        text = text.replace("buf (weak0, weak1)", "buf")
    if args.flop_delay:
        count = 0

        def delayed_output(match):
            nonlocal count
            count += 1
            indent, udp, output = match.groups()
            return (f"{indent}buf #({args.flop_delay}) MGMDLY_{count}( {output}, {output}_u );\n"
                    f"{indent}{udp}( {output}_u,")

        text = re.sub(r"(\s*)(" + CELL_PREFIX + r"__udp_[a-z_]+)\(\s*(\w+),", delayed_output, text)
        print("delayed sequential cells:", count)
    write(args.out, (TIMESCALE if args.timescale else "") + text)


def primitives(args):
    """The UDP primitives. --init: power-up value of every flop and latch. Without it a four-state simulator keeps
    every flop that has no reset at X for ever."""
    text = read(args.src)
    if args.init is not None:
        text = text.replace("\ntable\n", f"\ninitial Q = 1'b{args.init};\ntable\n")
    write(args.out, (TIMESCALE if args.timescale else "") + text)


def sram(args):
    """The SRAM model starting with CEN deasserted (its initial block sets cen_dly to 0, an access)."""
    write(args.out, read(args.src).replace("  cen_dly        = 0;", "  cen_dly        = 1;"))


def netlist(args):
    """The netlist of the run. --no-supply-ports: without the VDD and VSS ports (the cell models declare the
    supplies). --no-comments: without comment lines (the header has one line too long for Icarus and TestMAX)."""
    text = read(args.src)
    if args.no_supply_ports:
        text = text.replace(" , VDD , VSS ) ;", " ) ;", 1)
        text = text.replace("input  VDD ;\n", "", 1).replace("input  VSS ;\n", "", 1)
    if args.no_comments:
        text = "".join(line for line in text.splitlines(keepends=True) if not line.startswith("//"))
    write(args.out, text)


def words(args):
    """The program as one 32-bit little-endian word per line, from its byte hex (@address lines and bytes)."""
    memory, address = {}, 0
    for line in read(args.src).splitlines():
        line = line.strip()
        if line.startswith("@"):
            address = int(line[1:], 16)
            continue
        for byte in line.split():
            memory[address] = int(byte, 16)
            address += 1
    first, last = min(memory), max(memory)
    program = [sum(memory.get(a + i, 0) << (8 * i) for i in range(4)) for a in range(first, last + 1, 4)]
    write(args.out, "\n".join(f"{word:08x}" for word in program) + "\n")
    print("program words:", len(program), " base 0x%x" % first)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="kind")
    sub.required = True
    for name, function in [("cells", cells), ("primitives", primitives), ("sram", sram), ("netlist", netlist),
                           ("words", words)]:
        p = sub.add_parser(name)
        p.add_argument("src")
        p.add_argument("out")
        p.set_defaults(function=function)
        if name == "cells":
            p.add_argument("--no-keeper", action="store_true")
            p.add_argument("--flop-delay")
            p.add_argument("--timescale", action="store_true")
        if name == "primitives":
            p.add_argument("--init", choices=["0", "1"])
            p.add_argument("--timescale", action="store_true")
        if name == "netlist":
            p.add_argument("--no-supply-ports", action="store_true")
            p.add_argument("--no-comments", action="store_true")
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
