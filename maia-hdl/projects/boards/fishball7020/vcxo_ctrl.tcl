create_bd_cell -type module -reference vctcxo_pll_core vcxo_ctrl

ad_connect clk_40 vcxo_ctrl/clk_40mhz
ad_connect pps vcxo_ctrl/sig_100khz
ad_connect vcxo_ctrl/pwm_out phase
ad_connect vcxo_ctrl/lock_ind lock
ad_connect util_ad9361_divclk_reset/peripheral_reset vcxo_ctrl/reset
