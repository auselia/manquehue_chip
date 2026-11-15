# Simulation and firmware targets. Included by the Makefile.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  BIN (a program .hex), RISCV_PREFIX (default riscv32-none-elf-)
# out: sim/build/, sim/sw/**/bin/

# Default program. Example: make run BIN=sim/sw/hello_world/bin/test/test_gpio.hex
BIN ?= sim/sw/hello_world/bin/helloworld.hex
# The program folder of BIN under sim/sw/. sim, run and the VCS targets build it before they run it.
PROG = $(if $(filter sim/sw/%,$(BIN)),$(word 3,$(subst /, ,$(BIN))))
BUILD_PROG = $(if $(PROG),scripts/sim/build_sw.sh $(PROG),true)

##@ Simulation
.PHONY: sim sw clean-sw verilate run sim-spi vcs-compile run-vcs sim-vcs clean-sim
sim: ## Verilator: build the model and run BIN (default helloworld)
	@$(BUILD_PROG)
	@echo "[SIM] Launching Verilator simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash ../scripts/sim/run_verilator.sh
sw: ### build all RISC-V programs of sim/sw (the shared library is sim/sw/lib)
	@echo "[SW] Compiling RISC-V bare-metal software..."
	@scripts/sim/build_sw.sh
clean-sw: ### remove the program binaries
	@echo "[SW] Cleaning software binaries..."
	@scripts/sim/build_sw.sh clean
verilate: ### build the Verilator model only (again after every RTL change)
	@echo "[SIM] Compiling Verilator hardware model..."
	@cd sim && BUILD_ONLY=1 bash ../scripts/sim/run_verilator.sh
run: ### run BIN on the built Verilator model, no rebuild of the model
	@$(BUILD_PROG)
	@echo "[SIM] Running $(BIN) ..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash ../scripts/sim/run_verilator.sh
sim-spi: ### block testbench of the SPI block (sim/tb/tb_obi_spi.sv) in Verilator, after a lint run
	@echo "[SIM] SPI block testbench..."
	@bash scripts/sim/run_obi_spi_tb.sh
vcs-compile: ### build the VCS model only
	@echo "[SIM] Compiling VCS hardware model..."
	@cd sim && BUILD_ONLY=1 bash ../scripts/sim/run_vcs.sh
run-vcs: ### run BIN on the built VCS model
	@$(BUILD_PROG)
	@echo "[SIM] Running $(BIN) on VCS..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash ../scripts/sim/run_vcs.sh
sim-vcs: ### VCS: build the model and run BIN
	@$(BUILD_PROG)
	@echo "[SIM] Launching full VCS simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash ../scripts/sim/run_vcs.sh
clean-sim: ### remove sim/build/
	@echo "[SIM] Cleaning simulation builds..."
	@rm -rf sim/build/*
