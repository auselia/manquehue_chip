# DFT targets of a finished run. Included by the Makefile.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  RUN_DIR, the options of scripts/utils/env.sh (NPAT, DFT_REPLAY, JOBS)
# out: outputs/<run>/checks/dft/

##@ DFT of a run
.PHONY: dft dft-serial
dft: ## scan chain trace, ATPG, pattern replay (NPAT=20 for a quick run), SRAM March test
	RUN=$(RUN_DIR) scripts/dft/run_dft.sh
dft-serial: ### dft with the serial replay of every pattern (hours), for a full sign-off
	RUN=$(RUN_DIR) DFT_REPLAY=serial scripts/dft/run_dft.sh
