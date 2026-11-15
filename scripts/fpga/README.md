# FPGA (ZedBoard)

croc on the ZedBoard (Zynq-7000 PL), for the bring-up of the board and of its peripherals.

```
make fpga                                   # Vivado batch build: work_fpga/croc_zedboard_top.bit
sim/sw/fpga_bringup/build.sh s0_hello       # a bring-up step (on Rocky)
scripts/fpga/bench/load.sh s0_hello         # load it over the J-Link (on the Mac)
```

- `zedboard.xdc` maps the croc ports to the board. `openocd-croc.cfg` is the one OpenOCD configuration.
- `bench/` has the host tools: `load.sh`, the scope and AD2 tools, the OpenOCD probes and the Heltec sketches.
- `load.sh` reads the images from `sim/sw/fpga_bringup/bin`. Copy that folder from Rocky to the Mac first.
- `sim/sw/fpga_bringup/README.md` is the reference: the steps, the pins, the results on the board.
- The UART runs at 113636 baud: 20 MHz / (16 x 115200), rounded to 11. That is 1.4 % below 115200, so a 115200
  receiver reads it.
