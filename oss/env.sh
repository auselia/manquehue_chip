# Open-source flow environment (Mac). Usage:  cd oss && nix develop path:$PWD   then   source env.sh
# Tools come from the pinned flake in this folder (same pins as the wafer.space template: LibreLane 3.1.0.dev2,
# OpenROAD, Yosys 0.66 + slang, KLayout 0.30.9, Magic, Netgen, OpenSTA 2.7.0).
# PDK: gf180mcu variant D, ciel version f6eeac7d (same as on Rocky), with the std-cell, IO, SRAM and PR libraries.
export OSS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export OSS_PDK_VERSION=f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7
export PDK_ROOT=$HOME/oss_flow/pdk/ciel/gf180mcu/versions/$OSS_PDK_VERSION
export PDK=gf180mcuD
export SCL=gf180mcu_fd_sc_mcu7t5v0
export PDK_DIR=$PDK_ROOT/$PDK
export STD_LIB_DIR=$PDK_DIR/libs.ref/$SCL
export SRAM_LIB_DIR=$PDK_DIR/libs.ref/gf180mcu_fd_ip_sram
export OPENRCX_DIR=$PDK_DIR/libs.tech/librelane
