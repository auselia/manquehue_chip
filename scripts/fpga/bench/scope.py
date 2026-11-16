#!/usr/bin/env python3
# SCPI to the Keysight MSOX4024A over LAN (socket port 5025).
#   python3 scope.py "*IDN?" ":WGEN:FREQ?"     each argument is one command, a query (ending in ?) prints the answer
import socket
import sys

HOST, PORT = "192.168.140.102", 5025


class Scope:
    def __init__(self, host=HOST, port=PORT, timeout=10):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.f = self.s.makefile("rb")

    def write(self, cmd):
        self.s.sendall((cmd + "\n").encode())

    def query(self, cmd):
        self.write(cmd)
        return self.f.readline().decode(errors="replace").strip()

    def close(self):
        self.s.close()


if __name__ == "__main__":
    sc = Scope()
    for c in sys.argv[1:]:
        if c.rstrip().endswith("?"):
            print(f"{c} -> {sc.query(c)}")
        else:
            sc.write(c)
    print(f"errors -> {sc.query(':SYST:ERR?')}")
    sc.close()
