set SCRIPTS /tmp/aus106/scripts
source $SCRIPTS/common/open_lib.tcl
open_block finish
source /tmp/aus106/atpg/dft_spec.tcl
create_test_protocol
dft_drc
puts "=== report_scan_path existing"
catch {report_scan_path -view existing_dft -chain all} m; puts $m
puts "=== write_test_protocol help"
catch {help write_test_protocol} m; puts $m
catch {write_test_protocol -test_mode all_dft_protocol -output croc_soc_full.stil} m; puts $m
catch {write_scan_def -output croc_soc.scandef} m; puts $m
exit
