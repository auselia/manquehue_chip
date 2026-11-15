# Write the test protocol of the finish block (the scan configuration of common/dft_spec.tcl)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: REPO=<repo> OUT=<file> fc_shell -batch -f export_stil.tcl      (in work/, dft.sh does it)
# in:  work/design.dlib, block finish
# out: OUT, the protocol in STIL
source $::env(REPO)/scripts/common/open_lib.tcl
open_block finish
source $::env(REPO)/scripts/common/dft_spec.tcl
create_test_protocol
dft_drc
write_test_protocol -output $::env(OUT)
exit
