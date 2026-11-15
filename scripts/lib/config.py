#!/usr/bin/env python3
# Reads the "set NAME value" lines of config/*.tcl for Bash and Make (Tcl reads the files with source)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: python3 scripts/lib/config.py sh | make | get NAME
# in:  config/*.tcl
# out: stdout. sh: NAME='value' lines for eval. make: NAME := value entries, separated by ";", for $(eval).
"""The config files have only "set NAME value" lines and comments. Any other line is an error, so the three
readers (Tcl, Bash, Make) always see the same values."""
import pathlib
import re
import shlex
import sys

CONFIG = pathlib.Path(__file__).resolve().parents[2] / "config"
SET = re.compile(r"set\s+([A-Za-z_]\w*)\s+(.+)$")


def value_of(raw, where):
    """The Tcl value of a word: "a b", {a b} or a bare word. Substitution is not allowed."""
    if raw[0] + raw[-1] in ('""', "{}"):
        raw = raw[1:-1]
    elif re.search(r"\s", raw):
        sys.exit(f"{where}: put a value with spaces in quotes")
    if re.search(r'[$\[\\;"{}]', raw):
        sys.exit(f"{where}: no substitution, quotes or ';' inside a value")
    return raw


def read():
    """All values of config/*.tcl, in file order. A name defined twice is an error."""
    values = {}
    for path in sorted(CONFIG.glob("*.tcl")):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            where = f"{path.name}:{n}"
            m = SET.match(line)
            if not m:
                sys.exit(f"{where}: only 'set NAME value' lines and comments are allowed")
            name, raw = m.group(1), m.group(2).strip()
            if name in values:
                sys.exit(f"{where}: {name} is already set")
            values[name] = value_of(raw, where)
    return values


def main(argv):
    values = read()
    if argv == ["sh"]:
        print("\n".join(f"{k}={shlex.quote(v)}" for k, v in values.items()))
    elif argv == ["make"]:
        print(";".join(f"{k} := {v}" for k, v in values.items()))
    elif len(argv) == 2 and argv[0] == "get" and argv[1] in values:
        print(values[argv[1]])
    else:
        sys.exit("usage: config.py sh | config.py make | config.py get NAME")


if __name__ == "__main__":
    main(sys.argv[1:])
