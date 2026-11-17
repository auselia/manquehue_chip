# Sign-off targets of a finished run. Included by the Makefile.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  RUN_DIR. The options of each check: pv/settings.sh, sta/settings.sh, power/power.sh, irdrop/rail.sh,
#      scripts/utils/env.sh (NPAT, DFT_REPLAY, JOBS for dft)
# out: outputs/<run>/{drc,lvs,sta_pt,lec_fm,...}/ and outputs/<run>/checks/<check>/summary.txt

##@ Sign-off of a run (RUN=<run>, default outputs/latest)
.PHONY: signoff scan-sta gls dft dft-serial drc lvs sta-pt lec drc-icv lvs-icv fill-icv power-pp power-saif rail
signoff: drc lvs sta-pt lec ## KLayout DRC and LVS, PrimeTime STA at 3 corners, Formality, then the summary
	RUN=$(RUN_DIR) scripts/signoff/signoff_summary.py
scan-sta: ## scan-shift STA, 3 corners
	RUN=$(RUN_DIR) scripts/signoff/sta/scan_sta.sh
gls: ## gate-level simulation: Verilator boot, flash boot, scan shift, Icarus and VCS (SDF) macro boot over JTAG
	RUN=$(RUN_DIR) scripts/signoff/gls/gls.sh
dft: ## scan chain trace, ATPG, pattern replay (NPAT=20 for a quick run), SRAM March test
	RUN=$(RUN_DIR) scripts/signoff/dft/dft.sh
dft-serial: ### dft with the serial replay of every pattern (hours), for a full sign-off
	RUN=$(RUN_DIR) DFT_REPLAY=serial scripts/signoff/dft/dft.sh
drc: ### KLayout DRC (GDS=<file> checks another GDS, for example a filled one)
	RUN=$(RUN_DIR) scripts/signoff/pv/drc.sh
lvs: ### KLayout LVS, the SRAMs as black boxes
	RUN=$(RUN_DIR) scripts/signoff/pv/lvs.sh
sta-pt: ### PrimeTime STA at 3 corners: setup at slow and typical, hold at fast
	RUN=$(RUN_DIR) scripts/signoff/sta/sta.sh
lec: ### Formality, RTL against the netlist of the run
	scripts/signoff/lec/run_lec.sh $(RUN_DIR)
drc-icv: ### IC Validator DRC, a cross-check of drc
	RUN=$(RUN_DIR) scripts/signoff/pv/drc_icv.sh
lvs-icv: ### IC Validator LVS, a cross-check of lvs
	RUN=$(RUN_DIR) scripts/signoff/pv/lvs_icv.sh
fill-icv: ### IC Validator metal fill into fill_icv/filled.gds (the GDS of the run does not change)
	RUN=$(RUN_DIR) scripts/signoff/pv/fill_icv.sh
power-pp: ### PrimePower, vectorless (PP_SAIF=<file> for real activity, PP_CORNERS="slow typical fast")
	RUN=$(RUN_DIR) scripts/signoff/power/power.sh
power-saif: ### PrimePower with the activity of a VCS gate-level boot: active and idle (WFI) power (needs make sta-pt)
	RUN=$(RUN_DIR) scripts/signoff/power/saif_power.sh
rail: ### RedHawk-SC voltage drop of the finish block in work/ (RAIL_VOLTAGE_DROP=static)
	scripts/signoff/irdrop/rail.sh
