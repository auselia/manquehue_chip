# Release target. Included by the Makefile.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  RUN_DIR, the files and the check summaries of the run
# out: outputs/<run>/release/ (OUT=<folder> writes elsewhere)

##@ Release of a run
.PHONY: release
release: ## the release files of a run and sha256sums.txt, in outputs/<run>/release/ (needs all checks PASS)
	RUN=$(RUN_DIR) scripts/release/release.sh
