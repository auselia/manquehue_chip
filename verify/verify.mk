# Verification targets (included by the top Makefile). Every step reads RUN (default outputs/latest, the newest
# Fusion Compiler run) and writes to <run>/verify/<step>/summary.txt. `make report` collects them into results/<commit>.md.
#
#   make signoff   LVS, DRC, functional STA (3 corners), Formality  (needs `make all` and `make pt_export` of this checkout)
#   make scan-sta  scan-shift STA, 3 corners
#   make gls       Verilator boot, scan shift, Icarus macro boot
#   make dft       scan chain trace, ATPG, pattern replay (NPAT=20 for a quick run), SRAM March test
#   make chip      chip flow with the pad ring, precheck (COB=0 to run it without --cob)
#   make check     scan-sta + gls + dft + chip, then the report
VERIFY_DIR := verify
# RUN is a folder name under outputs/ or an absolute path
RUN_DIR := $(if $(filter /%,$(RUN)),$(RUN),$(OUTPUTS_DIR)/$(RUN))

.PHONY: signoff scan-sta gls dft chip check report
signoff:
	$(MAKE) drc lvs sta-pt
	$(REPO_DIR)/scripts/fm/run_lec.sh $(RUN_DIR)
	RUN=$(RUN_DIR) $(VERIFY_DIR)/sta/signoff_summary.sh
scan-sta:
	RUN=$(RUN_DIR) $(VERIFY_DIR)/sta/scan_sta.sh
gls:
	RUN=$(RUN_DIR) $(VERIFY_DIR)/gls/run_gls_all.sh
dft:
	RUN=$(RUN_DIR) $(VERIFY_DIR)/dft/run_dft.sh
chip:
	RUN=$(RUN_DIR) $(VERIFY_DIR)/chip/run_chip_flow.sh
report:
	python3 $(VERIFY_DIR)/report.py $(RUN_DIR)
check: scan-sta gls dft chip report
