# Open-source flow for croc_soc (experiment branch `exp/open-flow`)

Goal: reproduce what the Fusion Compiler flow does for the `croc_soc` hard macro with open tools only
(Yosys + slang, OpenROAD/OpenSTA, KLayout, Magic, Netgen), in the style of
[pulp-platform/croc](https://github.com/pulp-platform/croc) (`yosys/` then `openroad/01..05` stages) on GF180MCU.
Nothing outside `oss/` is changed; the FC flow is untouched.

## Setup (Mac, done once)

- Tools: `cd oss && nix develop path:$PWD` (pins in `flake.lock` are the wafer.space template's: LibreLane
  3.1.0.dev2, OpenROAD, Yosys 0.66 + slang, KLayout 0.30.9, Magic 8.3.660, Netgen, OpenSTA 2.7.0).
- PDK: `~/oss_flow/pdk` (gf180mcu variant D, ciel `f6eeac7d`, same as Rocky), installed with
  `ciel enable --pdk-root ~/oss_flow/pdk --pdk-family gf180mcu -l gf180mcu_fd_sc_mcu7t5v0 -l gf180mcu_fd_pr
  -l gf180mcu_fd_io -l gf180mcu_fd_ip_sram f6eeac7d...`.
- `source env.sh` inside the shell sets `PDK_ROOT`, `PDK`, `SCL` and the library directories.
- Check: `./smoke_slang.sh` elaborates `croc_soc` (4 SRAM macros) with Yosys + slang.

## Files

| File | Purpose |
|---|---|
| `flake.nix`, `flake.lock` | tool environment (copy of the template's) |
| `env.sh` | PDK paths |
| `prep_rtl.py` | writes `build/`: SRAM wrapper without VDD/VSS ties, SRAM port stub, absolute flist |
| `smoke_slang.sh` | elaboration check |

## Differences to the FC flow that matter

- OpenROAD connects power pins by name; the RTL ties `VDD`/`VSS` of the SRAM instance to constants for FC, so the
  open flow uses a generated copy of `tc_sram.sv` without them.
- The SRAM has liberty views at all corners (ss 125C 4.5 V, tt 25C 5 V, ff -40C 5.5 V), the FC flow only had tt.
- Yosys does not infer clock gates; the 232 ICGs of the FC netlist have no open-flow counterpart yet.

## Synthesis (Phase 1) and gate-level simulation

- `yosys/run_synthesis.sh` (4 min on the Mac): 28385 std cells, 4147 flops, 815e3 um2 without SRAM, no clock gating.
- `sim/run_gls_oss.sh <hex>` with `GLS_NETLIST=...`: Verilator gate-level run of the repo testbench. The netlist
  passes `gls_mini` with the same timestamps as the RTL (`GLS OK` at 914450 ns, finish at 934200 ns) when the flop
  output delay is **0.5 ns**. With 0.1 ns it diverged after the core wake-up: the vendor SRAM model samples address
  and data at CLK + 100 ps (`Tdly`), exactly where a 0.1 ns flop delay changes them. Use `FLOPDELAY=0.5ns`.
- Build time: `GLS_OPT=-O0` compiles in 1.5 min but simulates at 0.45 us/s; `-O1` compiles in about 1.5 h on 8 GB
  and simulates at 4 us/s. Start the run with `-O0` for short programs.
