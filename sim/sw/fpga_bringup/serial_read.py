#!/usr/bin/env python3
# Reads a serial port (the Heltec receiver or bridge over USB, 115200 8N1) for <seconds> and prints and logs the lines.
# No pyserial needed. With --reset the ESP32 is reset first (RTS pulse on the CP2102), so its start line is seen.
#   python3 serial_read.py /dev/cu.usbserial-XXXX 30 [log] [--reset]
import os, sys, termios, time, select, fcntl, struct

port, secs = sys.argv[1], float(sys.argv[2])
log = next((a for a in sys.argv[3:] if not a.startswith("--")), None)
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; a[3] = 0
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
TIOCMBIS, TIOCMBIC, DTR, RTS = 0x8004746c, 0x8004746b, 0x002, 0x004
fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", DTR))           # DTR off: keep GPIO0 high (no download mode)
if "--reset" in sys.argv:
    fcntl.ioctl(fd, TIOCMBIS, struct.pack("I", RTS)); time.sleep(0.1)   # RTS = EN low: reset
    fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", RTS))
fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", RTS))            # RTS off always: macOS sets it on open, and RTS on
                                                            # holds the ESP32 in reset (EN low)
termios.tcflush(fd, termios.TCIFLUSH)
if log: open(log + ".ready", "w").close()
out = open(log, "wb") if log else None
end, buf = time.time() + secs, b""
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: d = os.read(fd, 4096)
        except BlockingIOError: continue
        buf += d
        if out: out.write(d); out.flush()
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            print(line.decode(errors="replace").rstrip(), flush=True)
os.close(fd)
