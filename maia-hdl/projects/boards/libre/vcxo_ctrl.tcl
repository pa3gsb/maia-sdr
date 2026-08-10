# vctcxo_lock (projects/common/libre-vctcxo-lock) replaces axi_vcxo_ctrl
# (projects/common/antsdr-hdl) on this board. Same external ports/base
# address, so this is a drop-in swap - but a different architecture
# internally: frequency is measured by counting VCTCXO edges against
# s00_axi_aclk (the PS-derived AXI clock, independent of the VCTCXO being
# disciplined) with a PI controller, rather than a PLL-derived sample
# clock with a bare proportional term. See
# projects/common/libre-vctcxo-lock/vctcxo_lock.md for why and the full
# register map. axi_vcxo_ctrl is untouched for other boards still using it.
set vctcxo_lock [ create_bd_cell -type ip -vlnv user.org:user:vctcxo_lock:1.0 vctcxo_lock ]
# libre board schematic shows a TI DAC5311IDCKR on the VCXO tune line.
set_property CONFIG.DEVICE {DAC7311} $vctcxo_lock
ad_connect vctcxo_lock/CLK_40M_DAC_DIN CLK_40M_DAC_DIN
ad_connect vctcxo_lock/CLK_40M_DAC_SCLK CLK_40M_DAC_SCLK
ad_connect vctcxo_lock/CLK_40M_DAC_nSYNC CLK_40M_DAC_nSYNC
ad_connect vctcxo_lock/CLKIN_10MHz CLKIN_10MHz
ad_connect vctcxo_lock/CLK_40MHz_FPGA CLK_40MHz_FPGA
ad_connect vctcxo_lock/PPS_GPS PPS_GPS
ad_connect vctcxo_lock/PPS_IN PPS_IN
ad_connect vctcxo_lock/PPS_LED PPS_LED
ad_connect vctcxo_lock/PPS_LOCKED PPS_LOCKED
ad_connect vctcxo_lock/REF_10M_LOCKED REF_10M_LOCKED
ad_cpu_interconnect 0x43C00000 vctcxo_lock