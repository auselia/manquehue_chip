# croc_soc: Fusion Compiler implementation, sign-off, simulation and FPGA targets. make help lists them.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make <target> [RUN=<run folder under outputs/, or a path>] [VAR=value ...]
# in:  scripts/, config/, rtl/
# out: work/ (Fusion Compiler library and tool files), outputs/<run>/ (a build and its checks)
#
# The options of a check are in its script (scripts/signoff/<check>/settings.sh). Give them on the command line:
# make drc DRC_EXTRA="--antenna --density". Each stage folder has a module.mk with its targets.

SHELL := /bin/bash
.DELETE_ON_ERROR:
.DEFAULT_GOAL := help

TOP         := croc_soc
WORK_DIR    := work
# the step logs, copied into outputs/<run>/logs/ by scripts/utils/archive_run.sh at the end of finish
LOGS_DIR    := $(WORK_DIR)/logs
OUTPUTS_DIR := outputs
REPO_DIR    := $(shell pwd)

# 06_finish.tcl writes every run to outputs/<TOP>_<YYYYMMDD_HHMMSS>/ and points outputs/latest at it. The checks
# read the run folder and write their results into it.
RUN     ?= latest
RUN_DIR := $(if $(filter /%,$(RUN)),$(RUN),$(OUTPUTS_DIR)/$(RUN))

##@ Implementation (Fusion Compiler, in work/)
# A target for every scripts/0*_*.tcl step: 01_read_rtl.tcl gives read_rtl, open_read_rtl and gui_read_rtl.
#: read_rtl .. finish ### one step, after the steps before it
#: open_<step> ### open the block of a step in fc_shell (gui_<step>: in the GUI)
define MAKE_FC_RULE
.PHONY: $2 open_$2 gui_$2

$2: $(WORK_DIR)/design.dlib/$2

open_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

gui_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -gui -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

$(WORK_DIR)/design.dlib/$2: $3 $1
	mkdir -p $(LOGS_DIR) && cd $(WORK_DIR) && set -o pipefail; \
	fc_shell -batch -f ../$1 | tee logs/$2.log && ../scripts/utils/archive_run.sh $2
endef

TCL_FILES = $(sort $(wildcard scripts/0*_*.tcl))

DEPENDENCY :=
$(foreach file,$(TCL_FILES),\
  $(eval base := $(shell echo $(notdir $(file)) | sed -E 's/^[0-9]+_(.*)\.tcl/\1/'))\
  $(eval $(call MAKE_FC_RULE,$(file),$(base),$(DEPENDENCY)))\
  $(eval DEPENDENCY := $(WORK_DIR)/design.dlib/$(base))\
)
# A helper that only one step sources: a change in it runs that step (and the steps after it) again.
$(WORK_DIR)/design.dlib/finish: scripts/common/drc_eco.tcl

.PHONY: all pt_export clean distclean
all: $(DEPENDENCY) ## all implementation steps: outputs/<run>/ with GDS, netlist, SDC and SPEF
	@echo "[FLOW] Fusion Compiler flow completed successfully up to the final TCL script."

# 06_finish.tcl writes the PrimeTime inputs already. This writes them again from the saved finish block.
pt_export: ### SDC, sign-off SDC, scan SDC and SPEF again from the finish block, into outputs/latest
	mkdir -p $(LOGS_DIR) && cd $(WORK_DIR) && set -o pipefail; \
	fc_shell -batch -f ../scripts/utils/pt_export.tcl | tee logs/pt_export.log && ../scripts/utils/archive_run.sh pt_export

clean: ### remove work/ (library, staged logs and reports)
	rm -rf $(WORK_DIR)
	@echo "Cleaned the work directory (staging of logs and reports included)."

distclean: clean ### clean, and remove outputs/ (all runs). Use with care
	rm -rf $(OUTPUTS_DIR)
	@echo "Also removed the outputs directory (exported GDS/netlists)."

# In flow order: make help lists the targets in this order.
include scripts/sim/module.mk
include scripts/signoff/module.mk
include scripts/dft/module.mk
include scripts/fpga/module.mk
include scripts/utils/module.mk
