###### SWEEPER ###########
	add_files -norecurse  ../common/sweeper_it.v
	create_bd_cell -type module -reference sweeper_it sweeper_io
	ad_connect sweeper_io/clk maia_sdr/clk_fastlock_out
	#ad_connect sweeper_io/clk axi_ad9361/l_clk
	ad_connect sweeper_io/reset axi_ad9361/rst
	ad_connect sweeper_io/profile_o maia_sdr/fastlock_profile_in
	ad_ip_instance util_vector_logic logic_orgpio [list \
	  C_OPERATION {or} \
	  C_SIZE 64 ]
	ad_connect logic_orgpio/Res gpio_o
	ad_connect sweeper_io/gpio_o logic_orgpio/Op1
	ad_connect sys_ps7/GPIO_O logic_orgpio/Op2