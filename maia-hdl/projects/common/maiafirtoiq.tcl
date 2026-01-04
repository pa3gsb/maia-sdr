#In order to be controled by iio		
ad_ip_instance xlslice decim_slice
ad_connect axi_ad9361/up_adc_gpio_out decim_slice/Din
	
#I	
ad_ip_instance axis_data_fifo interclk_i
create_bd_cell -type module -reference ad_bus_mux mux_decim_i

ad_ip_parameter interclk_i CONFIG.FIFO_DEPTH 16
ad_ip_parameter interclk_i CONFIG.FIFO_MODE 1
ad_ip_parameter interclk_i CONFIG.IS_ACLK_ASYNC 1
ad_ip_parameter interclk_i CONFIG.HAS_TLAST.VALUE_SRC USER
ad_ip_parameter interclk_i CONFIG.HAS_TLAST 0
ad_ip_parameter interclk_i CONFIG.TDATA_NUM_BYTES 2
ad_ip_parameter interclk_i CONFIG.SYNCHRONIZATION_STAGES 4 

#ad_connect interclk_i/m_axis_aclk  axi_ad9361/l_clk 
ad_connect interclk_i/m_axis_aclk  util_ad9361_divclk/clk_out
ad_connect sys_cpu_resetn interclk_i/s_axis_aresetn 
ad_connect  maia_sdr/decim_re_out interclk_i/s_axis_tdata
ad_connect  maia_sdr_clk/clk_out1 interclk_i/s_axis_aclk
ad_connect  maia_sdr/decim_strobe_out interclk_i/s_axis_tvalid
ad_connect interclk_i/m_axis_tdata mux_decim_i/data_in_1
ad_connect interclk_i/m_axis_tvalid mux_decim_i/valid_in_1


ad_connect mux_decim_i/select_path decim_slice/Dout
ad_connect util_ad9361_adc_fifo/dout_valid_0 mux_decim_i/valid_in_0
ad_connect util_ad9361_adc_fifo/dout_enable_0 mux_decim_i/enable_in_0
ad_connect util_ad9361_adc_fifo/dout_data_0 mux_decim_i/data_in_0
#ad_connect maia_sdr/decim_strobe_out mux_decim_i/valid_in_1
ad_connect util_ad9361_adc_fifo/dout_enable_0 mux_decim_i/enable_in_1
#ad_connect maia_sdr/decim_re_out mux_decim_i/data_in_1

#Q	
ad_ip_instance axis_data_fifo interclk_q
create_bd_cell -type module -reference ad_bus_mux mux_decim_q

ad_ip_parameter interclk_q CONFIG.FIFO_DEPTH 16
ad_ip_parameter interclk_q CONFIG.FIFO_MODE 1
ad_ip_parameter interclk_q CONFIG.IS_ACLK_ASYNC 1
ad_ip_parameter interclk_q CONFIG.HAS_TLAST.VALUE_SRC USER
ad_ip_parameter interclk_q CONFIG.HAS_TLAST 0
ad_ip_parameter interclk_q CONFIG.TDATA_NUM_BYTES 2
ad_ip_parameter interclk_q CONFIG.SYNCHRONIZATION_STAGES 4 

#ad_connect interclk_q/m_axis_aclk  axi_ad9361/l_clk 
ad_connect interclk_q/m_axis_aclk  util_ad9361_divclk/clk_out
ad_connect sys_cpu_resetn interclk_q/s_axis_aresetn 
ad_connect  maia_sdr/decim_im_out interclk_q/s_axis_tdata
ad_connect  maia_sdr_clk/clk_out1 interclk_q/s_axis_aclk
ad_connect  maia_sdr/decim_strobe_out interclk_q/s_axis_tvalid
ad_connect interclk_q/m_axis_tdata mux_decim_q/data_in_1
ad_connect interclk_q/m_axis_tvalid mux_decim_q/valid_in_1

ad_connect mux_decim_q/select_path decim_slice/Dout
ad_connect util_ad9361_adc_fifo/dout_valid_1 mux_decim_q/valid_in_0
ad_connect util_ad9361_adc_fifo/dout_enable_1 mux_decim_q/enable_in_0
ad_connect util_ad9361_adc_fifo/dout_data_1 mux_decim_q/data_in_0

#ad_connect maia_sdr/decim_strobe_out mux_decim_q/valid_in_1
ad_connect util_ad9361_adc_fifo/dout_enable_1 mux_decim_q/enable_in_1
#ad_connect maia_sdr/decim_im_out mux_decim_q/data_in_1

ad_connect mux_decim_i/data_out muxcs8/data_in_0
ad_connect mux_decim_i/valid_out muxcs8/valid_in_0
ad_connect mux_decim_i/valid_out muxcs8/valid_in_1

ad_connect mux_decim_i/data_out rxcs12_cs8/sample_in1
ad_connect mux_decim_q/data_out rxcs12_cs8/sample_in2

ad_connect rxcs12_cs8/combined_out muxcs8/data_in_1
ad_connect mux_decim_q/data_out util_ad9361_adc_pack/fifo_wr_data_1