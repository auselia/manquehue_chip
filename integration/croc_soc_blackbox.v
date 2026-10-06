// Blackbox port declaration for croc_soc, for use as a hardened macro in
// downstream integration flows (e.g. the wafer.space chip_top). Port list
// taken directly from the module header of the real gate-level netlist
// (outputs/latest/croc_soc.v) -- kept as a separate file rather than
// extracting a stub from that netlist automatically, since croc_soc.v is
// the actual implementation (5.9MB, thousands of internal nets) and this
// file only needs to match its external port list, not track its internals.

(* blackbox *)
module croc_soc (
    clk_i,
    rst_ni,
    ref_clk_i,
    testmode_i,
    status_o,
    jtag_tck_i,
    jtag_tdi_i,
    jtag_tdo_o,
    jtag_tms_i,
    jtag_trst_ni,
    uart_rx_i,
    uart_tx_o,
    qspi_clk_o,
    qspi_sd_o,
    qspi_sd_i,
    qspi_sd_en_o,
    qspi_csn_o,
    gpio_i,
    gpio_o,
    gpio_out_en_o,
    VDD,
    VSS
);

input        clk_i;
input        rst_ni;
input        ref_clk_i;
input        testmode_i;
output       status_o;

input        jtag_tck_i;
input        jtag_tdi_i;
output       jtag_tdo_o;
input        jtag_tms_i;
input        jtag_trst_ni;

input        uart_rx_i;
output       uart_tx_o;

output       qspi_clk_o;
output [3:0] qspi_sd_o;
input  [3:0] qspi_sd_i;
output [3:0] qspi_sd_en_o;
output [2:0] qspi_csn_o;

input  [1:0] gpio_i;
output [1:0] gpio_o;
output [1:0] gpio_out_en_o;

input        VDD;
input        VSS;

endmodule
