# Forwarded SCLK experiment (AUS-16, SPI spec section 6)

Question: can the ADC reader send the system clock to a pad as SCLK (full rate, 18.18 MHz, about 870 kS/s) through a clock-gate
cell and an inverter, and does this flow (Fusion Compiler synthesis, CTS, routing, the same libraries and corners as `croc_soc`)
handle a clock that leaves through a port?

Answer: **yes, with no special handling.** The numbers are below. It was run on 15 Oct 2026.

## What it is

| File | Content |
|---|---|
| `fwd_clk_toy.v` | frame engine of the ADC reader: state counter, CS, enable of the gate, 15-bit shift of SDO, result register. `icgtp_4` and an inverter make `adc_sclk_o` (idles high) |
| `tb_fwd_clk_toy.v` | RTL test against `sim/models/ads7057_model.v` at 55 ns: 30 frames, every result compared |
| `tb_fwd_clk_toy_gls.v` | the same test on the routed netlist |
| `constraints.sdc` | clock 55 ns, generated clock `sclk` on the port (inverted), CS and SDO constraints from datasheet tables 6.6 and 6.7 plus a pad and board budget |
| `run_fc.tcl` | `fc_shell -batch -f ../run_fc.tcl` in `work/`: elaborate, floorplan, `compile_fusion`, `clock_opt`, `route_auto`, `route_opt`, reports |

Frame: 20 clocks per sample. CS low in 19 clocks, 18 SCLK falling edges, CS rises one clock after the last, the next CS falls two clocks
after the last falling edge (110 ns, tACQ 95 ns).

## Results (STA with the CTS and routed design, 55 ns)

| | slow (4.5 V, 125 C) | typical (5.0 V, 25 C) | fast (5.5 V, -40 C) |
|---|---|---|---|
| SCLK latency at the port, rising edge | 2.31 ns | 1.31 ns | 0.85 ns |
| SCLK latency at the port, falling edge | 2.47 ns | 1.38 ns | not analysed |
| clock latency at the flops | 0.90 ns | 0.50 ns | 0.32 ns |
| SCLK late against the flops | 1.4 ns | 0.8 ns | 0.5 ns |
| rise to fall difference (duty cycle error) | 0.16 ns (0.3 %) | 0.07 ns | |
| SDO setup slack (19 ns off-chip budget) | **+5.27 ns** | +6.41 ns | |
| SDO hold slack | | | +34.2 ns |
| CS setup slack (7 ns tsu_CSCK + 5 ns spread) | +42.7 ns | +42.9 ns | |
| CS hold slack (8 ns tht_CKCS) | | | +19.6 ns |

- Duty cycle: the datasheet allows 45 to 55 % (2.75 ns at 55 ns). The error is 0.16 ns at worst. The pad (`bi_24t`) adds its own
  rise/fall difference outside the macro.
- The off-chip budget for SDO is the datasheet 10 ns (SCLK rising edge to data) plus 3 ns pad, 5 ns level translator and 1 ns trace.
  At 50 ns clock the SDO setup slack is 2.8 ns, and every extra nanosecond of translator delay takes one nanosecond away.
- RTL simulation and gate-level simulation of the routed netlist: 30 frames, 0 mismatches, 0 violations of the datasheet timing
  checks counted by the model (tACQ, tsu_CSCK, tht_CKCS, CS high time, duty).

## What the flow did

- CTS reported "1 master clocks and 1 generated clocks" and built the tree without options beyond the ones `croc_soc` uses.
- It put the gate cell (`icgtp_2`) on a CTS buffer, and drives the port with its own inverter (`clkinv_12`), which replaces the
  inverter of the RTL.
- Clock gating checks on the gate (enable and test enable) pass with 0.7 ns of hold slack in the fast corner.
- The generated clock must be written with `-add_delay` on the second `set_output_delay` of a port. Without it the first output delay is
  silently replaced and the CS setup check disappears ("No paths"). This cost half an hour.

## What it does not show

- No pad ring: the pad delays are in the constraints (a budget), not extracted.
- Chip level: the template STA (OpenSTA with the extracted timing model of the macro) must define the generated clock on the pad
  and the model must carry the clock arrival at the port. Not tried. To be checked at the first integration (AUS-18).
- Scan: the toy has a scan-less flop set. In test mode the gate is open (TE = testmode_i), SCLK toggles with the clock.
- A longer SDO budget (translator slower than 5 ns) is not absorbed by anything in this design. The option is to sample SDO on
  the falling edge of `clk_i`, which moves the capture point 27.5 ns later. It needs a negative-edge flop and the DFT flow to
  handle it. It is a register bit in the spec, off by default.
