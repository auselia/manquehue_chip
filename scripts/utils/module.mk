# Report and help targets. Included last by the Makefile.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  outputs/<run>/checks/<check>/summary.txt, the ## and ### comments of the Makefile and of every module.mk
# out: outputs/<run>/report.md, stdout

##@ All checks of a run
# Every check writes outputs/<run>/checks/<check>/summary.txt. report collects them into outputs/<run>/report.md.
.PHONY: check report help help-all
check: scan-sta gls dft report ## scan-sta, gls and dft, then the report
report: ## outputs/<run>/report.md from the summaries of the checks
	python3 scripts/utils/report.py $(RUN_DIR)

##@ Help
help: ## the main targets
	@awk -f scripts/utils/help.awk $(MAKEFILE_LIST)
help-all: ## all targets
	@awk -v all=1 -f scripts/utils/help.awk $(MAKEFILE_LIST)
