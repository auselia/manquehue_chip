# Test protocol of the finished block. Run in work/:  REPO=<repo> OUT=<file> fc_shell -batch -f export_stil.tcl
set SCRIPTS $::env(REPO)/scripts
source $SCRIPTS/common/open_lib.tcl
open_block finish
source $::env(REPO)/verify/dft/dft_spec.tcl
create_test_protocol
dft_drc
write_test_protocol -output $::env(OUT)
exit
