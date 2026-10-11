# Yosys synthesis of the croc_soc macro for gf180mcu_fd_sc_mcu7t5v0.
# Structure and ABC "lazy man" script after pulp-platform/croc yosys/scripts/yosys_synthesis.tcl
# (Apache-2.0, ETH Zurich and University of Bologna, Philippe Sauter); technology and top changed.
# Run via oss/yosys/run_synthesis.sh (current directory: oss/yosys).

source scripts/yosys_common.tcl
source scripts/init_tech_gf180.tcl

set abc_script [processAbcScript scripts/abc-opt.script]

yosys plugin -i slang.so
yosys read_slang --top $top_design -f $sv_flist \
        --compat-mode --keep-hierarchy \
        --allow-use-before-declare --ignore-unknown-modules

# keep these modules as separate hierarchy blocks (names are <module>$<instance> after yosys-slang)
foreach m {croc_soc croc_domain user_domain core_wrap cve2_register_file_ff cve2_cs_registers dmi_jtag dm_top gpio
           clint bootrom obi_timer croc_idma obi_uart soc_ctrl_regs tc_sram_impl} {
    yosys setattr -set keep_hierarchy 1 "t:${m}\$*"
}
foreach m {tc_clk* cdc_reset* cdc*phase_* cdc*_src* cdc*_dst* sync} {
    yosys setattr -set keep_hierarchy 1 "t:${m}\$*"
}

yosys blackbox "t:tc_sram_blackbox\$*"

# dont_touch on the outputs of async regs becomes keep, copied to the driving cells
yosys attrmap -rename dont_touch keep
yosys attrmap -tocase keep -imap keep="true" keep=1
yosys attrmvcp -copy -attr keep

# ---- elaboration (heavily borrowed from the yosys `synth` command) ----
yosys hierarchy -top $top_design
yosys check
yosys proc
yosys tee -q -o "${rep_dir}/${proj_name}_elaborated.rpt" stat
yosys write_verilog -norename -noexpr -attr2comment ${tmp_dir}/${proj_name}_yosys_elaborated.v

# ---- coarse (like `synth -run coarse -noalumacc`) ----
yosys opt_expr
yosys opt -noff
yosys fsm
yosys wreduce
yosys peepopt
yosys opt_clean
yosys opt -full
yosys booth
yosys share
yosys opt
yosys memory -nomap
yosys memory_map
yosys opt -fast

yosys opt_dff -sat -nodffe -nosdff
yosys share
yosys opt -full
yosys clean -purge

yosys write_verilog -norename -noexpr ${tmp_dir}/${proj_name}_yosys_abstract.v
yosys tee -q -o "${rep_dir}/${proj_name}_abstract.rpt" stat -width -tech cmos

yosys techmap
yosys opt -fast
yosys clean -purge
yosys tee -q -o "${rep_dir}/${proj_name}_generic.rpt" stat -tech cmos

# flatten everything except the kept modules
yosys flatten
yosys write_verilog -norename ${tmp_dir}/${proj_name}_flatten.v
yosys clean -purge

# ---- keep flip-flop names ----
yosys splitnets -format __v
yosys rename -wire -suffix _reg t:*DFF*
yosys write_verilog -norename ${tmp_dir}/${proj_name}_yosys_rename.v
yosys select -write ${rep_dir}/${proj_name}_registers.rpt t:*DFF*
yosys autoname t:*DFF* %n
yosys clean -purge

# ---- technology mapping ----
# flip-flops first, then ABC on the combinational clouds
yosys dfflibmap {*}$tech_cells_args {*}$dont_use_args
yosys abc {*}$tech_cells_args -D $period_ps -script $abc_script -constr src/abc.constr {*}$dont_use_args -showtmp
yosys clean -purge

# ---- prepare for OpenROAD ----
yosys write_verilog -norename -noexpr -attr2comment ${out_dir}/netlist_debug.v
# ports stay buses (qspi_sd_o[3:0], gpio_*): the macro pins must keep the names of integration/croc_soc_blackbox.v
yosys splitnets -format __v
yosys setundef -zero
yosys clean -purge
yosys hilomap -singleton -hicell {*}$tech_cell_tiehi -locell {*}$tech_cell_tielo

# ---- reports and netlist ----
yosys tee -q -o "${rep_dir}/${proj_name}_synth.rpt" check
yosys tee -q -o "${rep_dir}/${proj_name}_area.rpt" stat -top $top_design {*}$liberty_args
yosys tee -q -o "${rep_dir}/${proj_name}_area_logic.rpt" stat -top $top_design {*}$tech_cells_args
yosys write_verilog -noattr -noexpr -nohex -nodec ${out_dir}/${proj_name}_yosys.v
