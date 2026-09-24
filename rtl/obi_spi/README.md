# obi_spi -- OpenTitan spi_host on Croc's OBI fabric

Croc is OBI end-to-end; OpenTitan's `spi_host` speaks TileLink-UL. This
directory vendors just enough of `spi_host` (and its `tlul`/`prim`
dependencies) to run standalone, plus a small bridge that makes it look like
any other OBI subordinate to the rest of Croc.

## Layout

- `obi_tlul_bridge.sv` -- the actual OBI<->TL-UL translation. This is the
  piece that's specific to this integration; everything else is either
  vendored third-party RTL or a thin wrapper around it.
- `obi_spi_host.sv` -- Croc-facing top module: OBI subordinate port in,
  `spi_sck_o`/`spi_csb_o`/`spi_sd_*` pad signals out. Instantiate this from
  `user_domain.sv`, same pattern as `obi_qspi`.
- `top_pkg.sv`, `lc_ctrl_pkg.sv` -- minimal project-local stand-ins for two
  OpenTitan chip-generated/chip-wide packages that `spi_host`/`tlul_pkg`
  reference. Not vendored from upstream; see the comment in each file for why
  a hand-written 5-line stub is correct here instead of pulling in the real
  (much larger, chip-specific) packages.
- `vendor/opentitan/` -- unmodified files pulled from lowRISC/opentitan.
  Apache-2.0, per the SPDX header each file already carries.

## Why `earlgrey_silver_release_v3`, not `master`

`master`'s `spi_host` is wired into OpenTitan's newer chip-wide hardening:
RACL (register access-control policies), end-to-end command/response
integrity variants tied to it, a `passthrough_req_t`/`passthrough_rsp_t` port
pulled from `spi_device_pkg`, and `prim_alert_sender`/`prim_alert_pkg` for
their chip-wide alert bus. None of that is optional at the port level on
`master` -- using it here would mean vendoring several more IPs' worth of
infrastructure to stub out features we don't want.

`earlgrey_silver_release_v3` predates all of that (confirmed by grepping the
fetched RTL directly, not assumed). Its `spi_host.sv` has a plain TL-UL port,
no alert ports, and its `passthrough`/`pt_*` signals are internal-only
(literally commented `// TODO: Route passthru outputs to ports once structure
is defined` at this tag) -- there's no passthrough port surface to deal with
at all. It still has TL-UL command-integrity checking (`tlul_cmd_intg_chk`,
handled in `obi_tlul_bridge.sv` via `tlul_pkg::get_cmd_intg()`), which is a
real, unavoidable-and-satisfied requirement, not hardening we opted into.

If OpenTitan's `spi_host` gets a real functional fix upstream that matters
here, re-diff against a newer tag before blindly re-vendoring `master` --
budget for re-doing the RACL/alert/passthrough stubbing this README describes
avoiding.

## Dependency closure

The file list here is the result of fetching `spi_host`'s RTL, grepping it
for every `prim_*`/`tlul_*`/package reference, fetching those, and repeating
until nothing new turned up (checked by diffing referenced names against
files present). Two exceptions:

- `prim_subreg`/`prim_subreg_ext` are **not** duplicated here -- Croc already
  vendors them at `rtl/register_interface/lowrisc_opentitan/`. `spi_host_reg_top.sv`
  uses them from there.
- `tlul_assert.sv` is a formal-verification/lint-flow-only bind file, not
  needed for synthesis, and is omitted. `prim_assert_{dummy,standard,yosys}_macros.svh`
  *are* vendored, though -- `prim_assert.sv` conditionally includes one of
  them (selected by which of `VERILATOR`/`SYNTHESIS`/etc. is defined) and
  without them every `` `ASSERT``/`` `ASSERT_INIT``/`` `ASSERT_KNOWN`` use
  in the vendored FIFO/CDC modules fails to compile.
- `spi_host_command_cdc.sv`, `spi_host_data_cdc.sv` (and their own
  dependencies `prim_fifo_async.sv`, `prim_sync_reqack.sv`,
  `prim_sync_reqack_data.sv`) were missed on the first pass -- the dependency
  scan only grepped for `prim_*`/`tlul_*` names and missed spi_host's own
  `spi_host_*`-prefixed internal submodules. These exist because `spi_host.sv`
  unconditionally instantiates CDC logic between `clk_i` (TL-UL/register side)
  and `clk_core_i` (SPI shift-register side), even when both are tied to the
  same clock (as `obi_spi_host.sv` does) -- functionally correct either way,
  just a few cycles of extra latency crossing a clock to itself.
- `spi_host_command_queue.sv` and `spi_host_data_fifos.sv` don't exist at this
  tag -- that functionality is inlined directly in `spi_host_core.sv`/
  `spi_host.sv` here, not factored out yet. (Both names came from an earlier,
  wrong assumption based on `master`'s file layout; verified absent by
  checking nothing in this file set actually instantiates them.)
- `prim_flop.sv`/`prim_flop_2sync.sv` are vendored from
  `hw/ip/prim_generic/rtl/prim_generic_flop{,_2sync}.sv` and renamed. At this
  tag there's no `prim/rtl/prim_flop_2sync.sv` technology-selection wrapper
  yet (OpenTitan's build tooling aliased `prim_generic_*` to the plain name
  at build time, rather than via a checked-in wrapper file) -- `spi_host.sv`
  instantiates the plain `prim_flop_2sync`, so we rename the one concrete
  implementation we need instead of vendoring a whole technology-selection
  layer for a single flip-flop.

## Verified

Standalone Verilator lint (`--lint-only`) passes clean -- 0 errors, only
warnings, and every warning traced to either a pin OpenTitan's own generated
`spi_host_reg_top.sv` deliberately leaves unconnected, or a field this
bridge deliberately doesn't consume (e.g. response-side `rsp_intg`, per the
comment in `obi_tlul_bridge.sv`). None of the vendored/authored files
themselves have real errors or unexplained warnings.

`obi_spi_host_lint_harness.sv` in this directory is what makes that check
meaningful rather than trivial: `obi_spi_host`'s `obi_req_t`/`obi_rsp_t`
parameters default to plain `logic`, so linting it standalone with no
override would just fail on every struct-field access. The harness
instantiates it with Croc's real `sbr_obi_req_t`/`sbr_obi_rsp_t` (from
`croc_pkg`) instead, matching how `user_domain.sv` will actually use it. It's
verification scaffolding, not part of the design.

Not yet vendored/fetched at lint time but needed for the physical build: none
found missing -- the flist below is a complete, closed dependency set for
synthesis-equivalent elaboration.

Reproduce with (verilator available via nix, not on PATH by default on this
host):

```bash
/nix/store/*-verilator-5.046/bin/verilator --lint-only -Wall -Wno-fatal \
  -F flists/obi_spi_lint.flist --top-module obi_spi_host_lint_harness
```

**Update: `NumCS=2` is now done.** `spi_host_reg_pkg.sv`/`spi_host_reg_top.sv`
in `vendor/opentitan/` are regenerated for two chip selects, not the hjson
default of one. `spi_csb_o` is `[1:0]` and there are now two independently
addressable `CONFIGOPTS_0`/`CONFIGOPTS_1` registers (own clock
divider/CPOL/CPHA/timing each), selected per-transaction via `CSID` --
exactly the ADC-fast/LoRa-slow-on-one-bus split this was built for.

How, for reproducibility: `spi_host.sv` takes `NumCS` from
`spi_host_reg_pkg::NumCS`, a value baked in at *generation* time from
`spi_host.hjson`'s `param_list` entry -- not a module `#()` parameter you can
override at the instantiation site, and (this cost some debugging) not
something `regtool.py --param NumCS=2` can override either, since the hjson
never sets `local: false` on it, so reggen treats it as a fixed `LocalParam`
whose CLI-supplied "default" is silently accepted and then never read. The
only path that actually works is editing `spi_host.hjson` itself
(`default: "1"` -> `"2"` on the `NumCS` entry) and regenerating from that.
Two more gaps surfaced getting `regtool.py -r` to run at all, both fixed with
narrow local stand-ins rather than by vendoring the real subsystems:
`pkg_resources` (removed from current `setuptools`; pinned `setuptools<81` in
the throwaway venv used for this) and `from topgen import lib` in
`reg_pkg.sv.tpl` (needs exactly one 15-line formatting function out of a
500-line module with its own package-internal import chain -- copied that
one function verbatim into a local `topgen/lib.py` stub instead of vendoring
`util/topgen/`). Regeneration itself is a one-liner once those are sorted:

```bash
python3 util/regtool.py -r --outdir <out> hw/ip/spi_host/data/spi_host.hjson
```

Re-linted afterward with the same harness/flist above -- still 0 errors, and
the one new warning (`obi_spi_host_lint_harness.sv`'s own `spi_csb_o` port
was still hardcoded `[0:0]` from testing against the old `NumCS=1` files) was
in the harness, not the design; fixed by sizing it off
`spi_host_reg_pkg::NumCS` there too instead of a literal.

## Integration TODO (not done here)

- Wire `obi_spi_host`'s OBI port into `user_domain.sv`'s `UserDesign` OBI
  slot (currently the `obi_err_sbr` placeholder).
- Wire `spi_sck_o`/`spi_csb_o`/`spi_sd_*` through the pinmux described
  elsewhere in this project onto the repurposed pads (former `gpio0/1`,
  `uart_rx_i`/`uart_tx_o`, `status_o`).
- Wire `intr_error_o`/`intr_spi_event_o` into `user_domain.sv`'s
  `interrupts_o[3:0]` (currently tied to `'0`) if you want either as its own
  fast IRQ rather than polled via `spi_host`'s status registers.
- Set `spi_host`'s `CONFIGOPTS`/`CSID` registers per-device (ADC vs. LoRa) at
  firmware init time -- see the OpenTitan `spi_host` programmer's guide.
