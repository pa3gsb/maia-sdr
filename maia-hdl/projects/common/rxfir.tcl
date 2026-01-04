	# TODO ; delete existing nodes
	#ad_connect axi_ad9361/adc_data_q0 util_ad9361_adc_pack/fifo_wr_data_1
	#ad_connect  logic_or/Op1  axi_ad9361/dac_valid_i0
	#ad_connect axi_ad9361/adc_data_i0 rxcs12_cs8/sample_in1
	#ad_connect axi_ad9361/adc_data_q0 rxcs12_cs8/sample_in2
	#ad_connect rxcs12_cs8/combined_out muxcs8/data_in_1
	#ad_connect axi_ad9361/adc_valid_i0 muxcs8/valid_in_1

	ad_add_decimation_filter "rx_fir_decimator" 8 2 1 {61.44} {61.44} \
                         "$ad_hdl_dir/library/util_fir_int/coefile_int.coe"
	ad_ip_instance xlslice decim_slice
	#ad_connect axi_ad9361/l_clk rx_fir_decimator/aclk
	ad_connect util_ad9361_divclk/clk_out rx_fir_decimator/aclk
	ad_connect axi_ad9361/up_adc_gpio_out decim_slice/Din
	ad_connect rx_fir_decimator/active decim_slice/Dout

	
	ad_connect util_ad9361_adc_fifo/dout_valid_0 rx_fir_decimator/valid_in_0
	ad_connect util_ad9361_adc_fifo/dout_enable_0 rx_fir_decimator/enable_in_0
	ad_connect util_ad9361_adc_fifo/dout_data_0 rx_fir_decimator/data_in_0
	ad_connect util_ad9361_adc_fifo/dout_valid_1 rx_fir_decimator/valid_in_1
	ad_connect util_ad9361_adc_fifo/dout_enable_1 rx_fir_decimator/enable_in_1
	ad_connect util_ad9361_adc_fifo/dout_data_1 rx_fir_decimator/data_in_1

	ad_connect rx_fir_decimator/data_out_0 muxcs8/data_in_0
	ad_connect rx_fir_decimator/valid_out_0 muxcs8/valid_in_0
	ad_connect rx_fir_decimator/valid_out_0 muxcs8/valid_in_1

	ad_connect rx_fir_decimator/data_out_0 rxcs12_cs8/sample_in1
	ad_connect rx_fir_decimator/data_out_1 rxcs12_cs8/sample_in2

	ad_connect rxcs12_cs8/combined_out muxcs8/data_in_1
	ad_connect rx_fir_decimator/data_out_1 util_ad9361_adc_pack/fifo_wr_data_1