# -----------------------------------------------------------------------------
# This file was created at the Institute of Microelectronic Systems,
# Leibniz University Hannover. It is provided "as is" without
# warranty of any kind, express or implied, including but not
# limited to correctness or fitness for a particular purpose.
#
# Author: Viktor Schneider
# -----------------------------------------------------------------------------

# Technology settings, loaded after elaboration
read_parasitic_tech -layermap ${LPE_LAYERMAP} -tlup ${LPE_NXTGRD} -name ${LPE_SPEC}

# Routing direction of each metal layer
set_attribute [get_layers {Metal1 Metal3 Metal5 }] routing_direction horizontal
set_attribute [get_layers {Metal2 Metal4        }] routing_direction vertical

# Aligns the routing tracks with the pins of the 7-track cells
set_attribute [get_layers -filter "mask_name =~ metal*"] track_offset 0.28

# The PDK gives no diode protection data, so the protection is taken as unlimited. diode_mode 2 because the DRC
# deck also checks the top layer for antenna violations.
# metal_ratio 360: the deck limit is 400, but its ratio is wire perimeter x thickness to gate area (ANT.16), which
# FC does not compute the same way. A Metal2 net that FC passed came out at 427 in the deck, so FC gets 10 % margin.
define_antenna_rule -mode 4 -diode_mode 2 -metal_ratio 360 -cut_ratio 20

# Antenna analysis also on the port nets
set_app_options -name route.detail.default_port_external_gate_size -value 0.0
