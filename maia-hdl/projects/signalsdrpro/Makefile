####################################################################################
## Copyright 2018(c) Analog Devices, Inc.
## Auto-generated, do not modify!
####################################################################################

PROJECT_NAME := signalsdrpi


M_DEPS += ../../adi-hdl/projects/common/xilinx/adi_fir_filter_constr.xdc
M_DEPS += ../../adi-hdl/projects/common/xilinx/adi_fir_filter_bd.tcl
M_DEPS += ../../adi-hdl/library/common/ad_iobuf.v
M_DEPS += ../../adi-hdl/library/util_cdc/sync_bits.v
M_DEPS += ../../adi-hdl/library/common/util_pulse_gen.v
M_DEPS += ../../adi-hdl/library/common/ad_bus_mux.v
M_DEPS += ../../adi-hdl/library/axi_ad9361/axi_ad9361_delay.tcl
M_DEPS += ip_cores

LIB_DEPS += axi_ad9361
LIB_DEPS += axi_dmac
LIB_DEPS += xilinx/util_clkdiv
LIB_DEPS += axi_ad9361
LIB_DEPS += util_rfifo
LIB_DEPS += util_wfifo
LIB_DEPS += util_pack/util_cpack2
LIB_DEPS += util_pack/util_upack2

include ../../adi-hdl/projects/scripts/project-xilinx.mk

DEST = ../../../../tezuka_fw/board/tezuka/signalsdrpro/bitstream

ip_cores:
	$(MAKE) -C ../../ip

fsbl:
	bash -c "rm -rf build"
	bash -c "xsct create_fsbl_project.tcl"

install :
	bash -c "cp -f $(PROJECT_NAME).sdk/system_top.xsa $(DEST)/maia-iio/"
	bash -c "cp -f build/sdk/fsbl/Release/fsbl.elf $(DEST)/"
	bash "./all_overclock.sh"
	bash -c "cp -f build/sdk/fsbl/Release/fsbl*.elf $(DEST)/overclock/"
	bash -c "git describe > $(DEST)/overclock/bit.txt"
.PHONY: ip_cores fsbl install

all: ip_cores fsbl install