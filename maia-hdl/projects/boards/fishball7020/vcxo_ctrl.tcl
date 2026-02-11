create_bd_cell -type module -reference vctcxo_pll_core vcxo_ctrl

ad_connect clk_10 vcxo_ctrl/clk_10mhz
ad_connect pps vcxo_ctrl/sig_100khz
ad_connect vcxo_ctrl/phase_out phase
ad_connect vcxo_ctrl/lock_ind lock
ad_connect vcxo_ctrl/clk_100khz clk_100khz
ad_connect util_ad9361_divclk_reset/peripheral_reset vcxo_ctrl/reset

ad_ip_instance xlslice vcxo_slice
ad_connect axi_ad9361/up_dac_gpio_out vcxo_slice/Din
ad_connect vcxo_ctrl/enable vcxo_slice/Dout