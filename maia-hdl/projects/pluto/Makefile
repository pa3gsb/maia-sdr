####################################################################################
## Copyright (c) 2018 - 2021 Analog Devices, Inc.
### SPDX short identifier: BSD-1-Clause
####################################################################################

PROJECT_NAME := pluto

M_DEPS += ../common/xilinx/adi_fir_filter_constr.xdc
M_DEPS += ../common/xilinx/adi_fir_filter_bd.tcl
M_DEPS += ../../library/util_cdc/sync_bits.v
M_DEPS += ../../library/common/util_pulse_gen.v
M_DEPS += ../../adi-hdl/library/common/ad_iobuf.v
M_DEPS += ../../adi-hdl/library/axi_ad9361/axi_ad9361_delay.tcl
M_DEPS += ip_cores

LIB_DEPS += axi_ad9361

include ../../adi-hdl/projects/scripts/project-xilinx.mk

ip_cores:
	$(MAKE) -C ../../ip

.PHONY: ip_cores

fsbl:
	bash -c "rm -rf build"
	bash -c "xsct create_fsbl_project.tcl"
