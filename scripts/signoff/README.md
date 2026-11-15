# Sign-off

The checks of a finished run. Each one reads the run folder and writes its results into it.

```
make signoff              # KLayout DRC and LVS, PrimeTime STA (3 corners), Formality
make check                # scan-sta, gls, dft, then the report
make signoff RUN=<run>    # another run (a folder under outputs/, or a path)
```

- `pv/` DRC, LVS and metal fill. `sta/` STA and timing models. `lec/` Formality. `gls/` gate-level simulation.
  `dft/` ATPG and the SRAM March test. `power/`, `irdrop/` power and voltage drop (optional).
- The options of a check are in its script or in the `settings.sh` of its folder. Give them on the command line:
  `make drc DRC_EXTRA=--antenna`.
- Each check writes `outputs/<run>/checks/<check>/summary.txt`. Its last line is `status: PASS` or `status: FAIL`.
- `gls/README.md` is the reference of the gate-level simulation.
