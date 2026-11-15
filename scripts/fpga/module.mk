# FPGA targets (ZedBoard, Zynq-7000 PL). Included by the Makefile. Vivado must be on PATH.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  flists/croc_fpga.flist, constraints/zedboard.xdc
# out: work_fpga/

VIVADO ?= vivado

##@ FPGA (ZedBoard)
.PHONY: fpga clean-fpga
fpga: ## Vivado batch build: synthesis, place, route, bitstream in work_fpga/
	@echo "[FPGA] Running Vivado non-project build for the ZedBoard..."
	@$(VIVADO) -mode batch -source scripts/fpga/build_zedboard.tcl
clean-fpga: ### remove work_fpga/ and the Vivado logs
	rm -rf work_fpga vivado*.log vivado*.jou vivado*.str .Xil
	@echo "Cleaned FPGA build directory and Vivado logs."
