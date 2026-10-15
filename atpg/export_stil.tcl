set SCRIPTS /tmp/aus106/scripts
source $SCRIPTS/common/open_lib.tcl
open_block finish
source /tmp/aus106/atpg/dft_spec.tcl
create_test_protocol
dft_drc
write_test_protocol -output croc_soc.stil
exit
