# apb_i2c

I2C host (master) with an APB interface, from [pulp-platform/apb_i2c](https://github.com/pulp-platform/apb_i2c),
commit `84855413cc2c8e70209ee7f168a0225d3c5914a1`. The I2C controllers are the OpenCores I2C master by Richard Herveille (`i2c_master_bit_ctrl.sv`,
`i2c_master_byte_ctrl.sv`). Each file keeps its original copyright notice.

croc connects it through `rtl/obi/obi_to_apb.sv` (`rtl/croc_domain.sv`).

Local change (croc): `i2c_master_defines.sv` has an include guard and no `` `timescale``. The file is included three
times, and its 1 ns / 1 ns timescale leaked into the files compiled after it.

Lint (Verilator 5.052, -Wall, apb_i2c alone): 0 errors, 14 warnings, all reviewed and harmless. 10 WIDTHEXPAND (3-bit
register constants against the 4-bit address field), 2 UNUSEDSIGNAL (unused PADDR and PWDATA bits), 1 WIDTHTRUNC
(clk_cnt >> 2 into the 14-bit filter counter: the two dropped bits are always 0), 1 CASEINCOMPLETE (no write case
for the read-only RX and STATUS registers, inside a clocked block). The vendored code stays unchanged.
