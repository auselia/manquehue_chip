# Simulation

RTL simulation of croc with the firmware of `sim/sw`. The test benches are in `sim/tb`, the models in
`sim/models`.

```
make sim                  # Verilator: build the model, run BIN (default helloworld)
make regress              # SPI and FFT block test benches, model self-test, ZedBoard bring-up steps
make sw                   # all programs of sim/sw
```

- Every program uses the one library in `sim/sw/lib`: `program.mk` for a Makefile program, `../lib` in a `build.sh`.
- The programs build from source. No `.hex` is in git, so `make sim` builds the program of `BIN` first.
- The toolchain prefix is `riscv32-none-elf-` (`RISCV_PREFIX`). The ML demos need `riscv64-unknown-elf-`: the
  libgcc of riscv32-none-elf-gcc 16 is double-float.
- `make regress` writes `sim/build/regress/summary.txt`. `BRINGUP=0` skips the bring-up steps (about 5 minutes).
