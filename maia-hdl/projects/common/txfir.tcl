#delete_bd_objs [get_bd_nets -of_objects [find_bd_objs -relation connected_to [get_bd_pins axi_ad9361_dac_fifo/din_data_0]]]	
#delete_bd_objs [get_bd_nets -of_objects [find_bd_objs -relation connected_to [get_bd_pins axi_ad9361_dac_fifo/din_data_1]]]	   
delete_bd_objs [get_bd_nets -of_objects [find_bd_objs -relation connected_to [get_bd_pins logic_or/Op1]]]
delete_bd_objs [get_bd_nets -of_objects [find_bd_objs -relation connected_to [get_bd_pins logic_or/Op2]]]	   	   
delete_bd_objs [get_bd_nets -of_objects [find_bd_objs -relation connected_to [get_bd_pins util_ad9361_dac_upack/fifo_rd_en]]]	   
#ad_add_interpolation_filter "tx_fir_interpolator" 8 2 1 {61.44} {7.68} \
#							"$ad_hdl_dir/library/util_fir_int/coefile_int.coe"

ad_add_interpolation_filter "tx_fir_interpolator" 32 2 1 {61.44} {1.92} \
                    "$ad_hdl_dir/../projects/pluto/firinterp32.coe"

ad_ip_instance xlslice interp_slice

ad_connect util_ad9361_divclk/clk_out tx_fir_interpolator/aclk

ad_connect muxcs8_tx_i/enable_out tx_fir_interpolator/dac_enable_0
#ad_connect axi_ad9361_dac_fifo/dout_valid_out_0 tx_fir_interpolator/dac_valid_0
ad_connect axi_ad9361_dac_fifo/din_valid_0 tx_fir_interpolator/dac_valid_0
ad_connect muxcs8_tx_i/data_out tx_fir_interpolator/data_in_0
ad_connect muxcs8_tx_q/enable_out tx_fir_interpolator/dac_enable_1
#ad_connect axi_ad9361_dac_fifo/dout_valid_out_1 tx_fir_interpolator/dac_valid_1
ad_connect axi_ad9361_dac_fifo/din_valid_1 tx_fir_interpolator/dac_valid_1
ad_connect muxcs8_tx_q/data_out tx_fir_interpolator/data_in_1

ad_connect axi_ad9361/up_dac_gpio_out interp_slice/Din
ad_connect  tx_fir_interpolator/active interp_slice/Dout
#ad_connect  logic_or/Op1  tx_fir_interpolator/valid_out_0
ad_connect  tx_fir_interpolator/valid_out_0 util_ad9361_dac_upack/fifo_rd_en
ad_connect axi_ad9361_dac_fifo/din_data_0 tx_fir_interpolator/data_out_0
ad_connect axi_ad9361_dac_fifo/din_data_1 tx_fir_interpolator/data_out_1
