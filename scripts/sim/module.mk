# Simulation and firmware targets. Included by the Makefile.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  BIN (a program .hex), RUN_DIR (gls)
# out: sim/build/, sim/sw/**/bin/, outputs/<run>/checks/gls/

# Default program. Example: make run BIN=sim/sw/bin/test/test_gpio.hex
BIN ?= sim/sw/hello_world/bin/helloworld.hex

##@ Simulation
.PHONY: sim gls sw clean-sw verilate run sim-spi vcs-compile run-vcs sim-vcs clean-sim
sim: ## Verilator: build the model and run BIN (default helloworld)
	@echo "[SIM] Launching Verilator simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash ../scripts/sim/run_verilator.sh
gls: ## gate-level simulation of a run: Verilator boot, scan shift, Icarus macro boot over JTAG
	RUN=$(RUN_DIR) scripts/sim/run_gls_all.sh
sw: ### build the RISC-V programs
	@echo "[SW] Compiling RISC-V bare-metal software..."
	@$(MAKE) -C sim/sw
clean-sw: ### remove the program binaries
	@echo "[SW] Cleaning software binaries..."
	@$(MAKE) -C sim/sw clean
verilate: ### build the Verilator model only (again after every RTL change)
	@echo "[SIM] Compiling Verilator hardware model..."
	@cd sim && BUILD_ONLY=1 bash ../scripts/sim/run_verilator.sh
run: sw ### run BIN on the built Verilator model, no rebuild
	@echo "[SIM] Running $(BIN) ..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash ../scripts/sim/run_verilator.sh
sim-spi: ### block testbench of the SPI block (sim/tb/tb_obi_spi.sv) in Verilator, after a lint run
	@echo "[SIM] SPI block testbench..."
	@bash scripts/sim/run_obi_spi_tb.sh
vcs-compile: ### build the VCS model only
	@echo "[SIM] Compiling VCS hardware model..."
	@cd sim && BUILD_ONLY=1 bash ../scripts/sim/run_vcs.sh
run-vcs: sw ### run BIN on the built VCS model
	@echo "[SIM] Running $(BIN) on VCS..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash ../scripts/sim/run_vcs.sh
sim-vcs: sw ### VCS: build the model and run BIN
	@echo "[SIM] Launching full VCS simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash ../scripts/sim/run_vcs.sh
clean-sim: ### remove sim/build/
	@echo "[SIM] Cleaning simulation builds..."
	@rm -rf sim/build/*
