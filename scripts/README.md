# Implementation

Six Fusion Compiler steps build `croc_soc` as a hard macro: `01_read_rtl`, `02_floorplan` (outline, pins, power
grid), `03_synthesis` (with scan insertion), `04_cts`, `05_route`, `06_finish`.

```
make all                  # all steps
make cts                  # one step, after the steps before it
make gui_cts              # the block of a step in the FC GUI
```

- In: `rtl/`, `flists/croc.flist`, `config/`. Out: one block per step in `work/design.dlib`. `06_finish` writes
  the run folder `outputs/croc_soc_<timestamp>/`: GDS, netlist, LEF, black box, SDC and SPEF of every corner.
- `common/` has what more than one step uses: setup, corners and modes, constraints, power grid, DFT, ECOs.
- `chip/padring.txt` sets the pin positions: each pin faces its pad on the AC3E ring.
- A change in a step script runs that step and the steps after it again.
