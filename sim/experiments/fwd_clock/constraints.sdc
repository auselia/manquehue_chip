# Forwarded-clock experiment: constraints of fwd_clk_toy, ADS7057 interface (datasheet SBAS821 tables 6.5 to 6.7)
set T 55.0
create_clock -name clk -period $T [get_ports clk_i]
set_clock_uncertainty -setup 0.7  [get_clocks clk]
set_clock_uncertainty -hold  0.35 [get_clocks clk]

# SCLK: the system clock through the gate and an inverter, leaves through the port
create_generated_clock -name sclk -source [get_ports clk_i] -divide_by 1 -invert [get_ports adc_sclk_o]

# off-chip budget: pad out 7 to 12 ns on every output (clock and data alike, so it cancels between SCLK and CS), pad in 3 ns,
# translator 5 ns, trace 1 ns
set PAD_OUT_SPREAD 5.0      ;# difference between the slowest data pad and the clock pad
# CS: low at least 7 ns before the first SCLK falling edge (tsu_CSCK), rise at least 8 ns after the SCLK rising edge (tht_CKCS)
set_output_delay -clock sclk -clock_fall -max [expr {7.0 + $PAD_OUT_SPREAD}] [get_ports adc_csn_o]
set_output_delay -clock sclk             -min -8.0 -add_delay              [get_ports adc_csn_o]
# SDO: launched by the SCLK rising edge, valid 10 ns max after it, held 2.5 ns min, plus pad, translator and trace
set_input_delay -clock sclk -max [expr {10.0 + 3.0 + 5.0 + 1.0}] [get_ports adc_sdo_i]
set_input_delay -clock sclk -min [expr {2.5 + 1.0 + 3.0}] -add_delay [get_ports adc_sdo_i]

# the rest of the ports, off-chip side of a pad ring
set_input_delay  -clock clk -max 11.0 [get_ports {run_i testmode_i rst_ni}]
set_input_delay  -clock clk -min 1.0  [get_ports {run_i testmode_i rst_ni}]
set_output_delay -clock clk -max 11.0 [get_ports {code_o* valid_o}]
set_output_delay -clock clk -min 0.0  [get_ports {code_o* valid_o}]
set_load 0.2 [all_outputs]
set_input_transition 0.3 [remove_from_collection [all_inputs] [get_ports clk_i]]
set_false_path -from [get_ports rst_ni]
