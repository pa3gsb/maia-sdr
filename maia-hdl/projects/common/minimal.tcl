# JUST THE PLUTO BARE MINIMAL to start wuth Custom
# NO DECIM/INTERPOLATOR

# CONNECT DMA TO HP_AXIS 

ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP1 {1}
ad_connect sys_cpu_clk sys_ps7/S_AXI_HP1_ACLK
ad_connect axi_ad9361_adc_dma/m_dest_axi sys_ps7/S_AXI_HP1

#Check RANGE : Fixme
# Having a wrong range seems make all samples to zero !

create_bd_addr_seg -range 0x40000000 -offset 0x00000000 \
                    [get_bd_addr_spaces axi_ad9361_adc_dma/m_dest_axi] \
                    [get_bd_addr_segs sys_ps7/S_AXI_HP1/HP1_DDR_LOWOCM] \
                    SEG_sys_ps7_HP1_DDR_LOWOCM

ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP2 {1}
ad_connect sys_cpu_clk sys_ps7/S_AXI_HP2_ACLK
ad_connect axi_ad9361_dac_dma/m_src_axi sys_ps7/S_AXI_HP2

#Check RANGE : Fixme
create_bd_addr_seg -range 0x40000000 -offset 0x00000000 \
                    [get_bd_addr_spaces axi_ad9361_dac_dma/m_src_axi] \
                    [get_bd_addr_segs sys_ps7/S_AXI_HP2/HP2_DDR_LOWOCM] \
                    SEG_sys_ps7_HP2_DDR_LOWOCM

