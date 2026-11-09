#!/usr/bin/env python3
# croc UART through an Analog Discovery 2 (WaveForms SDK): croc uart_tx_o (JB1) on DIO 0, GND on JB5.
# Prints what croc sends, for <seconds> (0 = until Ctrl-C), and writes it to <log> if given.
#   python3 ad2_uart.py 20 out.log
# croc runs at 20 MHz, and uart_init truncates 20 MHz / (16 * 115200) = 10.85 to 10: 125000 baud, 8.5 % above
# 115200 (measured on JB1 with ad2_bittime.py, 8.0 us per bit). A 115200 receiver cannot read it, the AD2 takes
# 125000 exactly. Close the WaveForms app first: only one program can open the AD2.
import sys, time
from ctypes import cdll, c_int, c_double, byref, create_string_buffer

BAUD = 125000
RX_DIO = 0
TX_DIO = 1  # the SDK needs a TX pin: DIO 1, leave it unconnected

dwf = cdll.LoadLibrary("/Library/Frameworks/dwf.framework/dwf")
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 0
log = open(sys.argv[2], "wb") if len(sys.argv) > 2 else None

h = c_int()
if dwf.FDwfDeviceOpen(c_int(-1), byref(h)) == 0 or h.value == 0:
    err = create_string_buffer(512); dwf.FDwfGetLastErrorMsg(err)
    sys.exit("AD2 open failed: " + err.value.decode(errors="replace"))
dwf.FDwfDigitalUartRateSet(h, c_double(BAUD))
dwf.FDwfDigitalUartTxSet(h, c_int(TX_DIO))
dwf.FDwfDigitalUartRxSet(h, c_int(RX_DIO))
dwf.FDwfDigitalUartBitsSet(h, c_int(8))
dwf.FDwfDigitalUartParitySet(h, c_int(0))
dwf.FDwfDigitalUartStopSet(h, c_double(1))
n, par = c_int(), c_int()
dwf.FDwfDigitalUartRx(h, None, c_int(0), byref(n), byref(par))  # start the receiver
print(f"AD2 UART ready: DIO {RX_DIO}, {BAUD} 8N1", file=sys.stderr, flush=True)
if log: open(log.name + ".ready", "w").close()

buf = create_string_buffer(8193)
end = time.time() + secs if secs > 0 else None
try:
    while end is None or time.time() < end:
        time.sleep(0.05)
        dwf.FDwfDigitalUartRx(h, buf, c_int(8192), byref(n), byref(par))
        if n.value > 0:
            data = buf.raw[:n.value]
            sys.stdout.write(data.decode("ascii", errors="replace")); sys.stdout.flush()
            if log: log.write(data); log.flush()
        if par.value < 0:
            print("\n[AD2: receive buffer overflow]", file=sys.stderr)
        elif par.value > 0:
            print("\n[AD2: parity or framing error]", file=sys.stderr)
except KeyboardInterrupt:
    pass
finally:
    dwf.FDwfDeviceCloseAll()
