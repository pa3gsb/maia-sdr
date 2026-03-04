create_bd_cell -type module -reference vctcxo_pll_core vcxo_ctrl

ad_connect clk_10 vcxo_ctrl/clk_10mhz
ad_connect pps vcxo_ctrl/sig_pps
ad_connect vcxo_ctrl/phase_out phase
ad_connect vcxo_ctrl/lock_ind lock
ad_connect vcxo_ctrl/mmcm_clkout /outclk
ad_connect util_ad9361_divclk_reset/peripheral_reset vcxo_ctrl/reset
