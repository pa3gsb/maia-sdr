# CS8 Capabitiy

# ======================= 8BITS RX OUT  ============================
	add_files -norecurse  ../pluto/cs12_cs8.v
	create_bd_cell -type module -reference cs12_cs8 rxcs12_cs8
	#ad_connect axi_ad9361/adc_data_i0 rxcs12_cs8/sample_in1
	#ad_connect axi_ad9361/adc_data_q0 rxcs12_cs8/sample_in2
	
	#Mux select CS8
	#Select input depending on qo_enable
	ad_ip_instance util_vector_logic logic_no_q0 [list \
	  C_OPERATION {not} \
	  C_SIZE 1]
	ad_connect util_ad9361_adc_fifo/dout_enable_1 logic_no_q0/Op1
	#ad_ip_instance ad_bus_mux muxcs8 -> DOESNT WORK , USE create_bd_cell instead
	add_files -norecurse  ../../adi-hdl/library/common/ad_bus_mux.v
	create_bd_cell -type module -reference ad_bus_mux muxcs8
	ad_connect muxcs8/select_path logic_no_q0/Res

	#First input CS16 - > I0 -> I0
	ad_connect util_ad9361_adc_fifo/dout_enable_0 muxcs8/enable_in_0

	#Second input CS8 - > I0+Q0
	ad_connect GND muxcs8/enable_in_1

	#OUT
	ad_connect muxcs8/valid_out util_ad9361_adc_pack/fifo_wr_en
	ad_connect muxcs8/data_out util_ad9361_adc_pack/fifo_wr_data_0
	ad_connect muxcs8/enable_out util_ad9361_adc_pack/enable_1

	# ======================= 8BITS TX OUT  ============================
	# I PART
	ad_ip_instance xlslice shiftsliceitx
	ad_ip_parameter shiftsliceitx CONFIG.DIN_WIDTH 16
	ad_ip_parameter shiftsliceitx CONFIG.DIN_FROM 15
	ad_ip_parameter shiftsliceitx CONFIG.DIN_TO 8
	ad_ip_parameter shiftsliceitx CONFIG.DOUT_WIDTH 8
	ad_connect util_ad9361_dac_upack/fifo_rd_data_0 shiftsliceitx/Din
	
	ad_ip_instance xlconcat concatslicetx_i

	
	ad_ip_parameter concatslicetx_i CONFIG.NUM_PORTS 2
	ad_ip_parameter concatslicetx_i CONFIG.IN0_WIDTH 8
	ad_ip_parameter concatslicetx_i CONFIG.IN1_WIDTH 8
	

	ad_connect shiftsliceitx/Dout concatslicetx_i/In1
	
	# Q PART
	ad_ip_instance xlslice shiftsliceqtx
	ad_ip_parameter shiftsliceqtx CONFIG.DIN_WIDTH 16
	ad_ip_parameter shiftsliceqtx CONFIG.DIN_FROM 7
	ad_ip_parameter shiftsliceqtx CONFIG.DIN_TO 0
	ad_ip_parameter shiftsliceqtx CONFIG.DOUT_WIDTH 8
	ad_connect util_ad9361_dac_upack/fifo_rd_data_0 shiftsliceqtx/Din

	ad_ip_instance xlconcat concatslicetx_q
	ad_ip_parameter concatslicetx_q CONFIG.NUM_PORTS 2
	ad_ip_parameter concatslicetx_q CONFIG.IN0_WIDTH 8
	ad_ip_parameter concatslicetx_q CONFIG.IN1_WIDTH 8

	ad_connect shiftsliceqtx/Dout concatslicetx_q/In1

	ad_ip_instance util_vector_logic logic_no_q0_tx [list \
	  C_OPERATION {not} \
	  C_SIZE 1]
	ad_connect axi_ad9361_dac_fifo/din_enable_0 logic_no_q0_tx/Op1

	#Select input depending on dac_qo_enable
	# *****  I PART **********

	create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_i

	ad_connect muxcs8_tx_i/select_path logic_no_q0_tx/Res
	ad_connect muxcs8_tx_i/enable_in_0 axi_ad9361_dac_fifo/din_enable_0
	#First input CS16 - > I0 -> I0
	ad_connect util_ad9361_dac_upack/fifo_rd_data_0 muxcs8_tx_i/data_in_0
	#Second input C8 - > CS16 > I0
	ad_connect concatslicetx_i/Dout muxcs8_tx_i/data_in_1
	ad_connect muxcs8_tx_i/enable_in_1 axi_ad9361_dac_fifo/din_enable_0

	#OUT if not fir
	# ad_connect muxcs8_tx_i/data_out axi_ad9361_dac_fifo/din_data_0

	ad_connect muxcs8_tx_i/enable_out util_ad9361_dac_upack/enable_0

	#Select input depending on dac_qo_enable
	# *****  Q PART **********

	create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_q

	ad_connect muxcs8_tx_q/select_path logic_no_q0_tx/Res
	ad_connect muxcs8_tx_q/enable_in_0 axi_ad9361_dac_fifo/din_enable_1
	#First input CS16 - > I0 -> I0
	ad_connect util_ad9361_dac_upack/fifo_rd_data_1 muxcs8_tx_q/data_in_0
	#Second input C8 - > CS16 > I0
	ad_connect concatslicetx_q/Dout muxcs8_tx_q/data_in_1
	#ad_connect muxcs8_tx_q/enable_in_1 axi_ad9361_dac_fifo/din_enable_0
	ad_connect muxcs8_tx_q/enable_in_1 axi_ad9361_dac_fifo/din_enable_1

	#OUT without fir
	#ad_connect muxcs8_tx_q/data_out axi_ad9361_dac_fifo/din_data_1
	ad_connect muxcs8_tx_q/enable_out util_ad9361_dac_upack/enable_1

	# ******************************************************************
	#                       2ND CHANNEL 
	#

	# ======================= 8BITS RX2 OUT  ============================
	
	
	create_bd_cell -type module -reference cs12_cs8 rxcs22_cs8
	ad_connect util_ad9361_adc_fifo/dout_data_2 rxcs22_cs8/sample_in1
	ad_connect util_ad9361_adc_fifo/dout_data_3 rxcs22_cs8/sample_in2
	
	#Mux select CS8
	#Select input depending on qo_enable
	ad_ip_instance util_vector_logic logic_no_q1 [list \
	  C_OPERATION {not} \
	  C_SIZE 1]
	ad_connect util_ad9361_adc_fifo/dout_enable_3 logic_no_q1/Op1

	create_bd_cell -type module -reference ad_bus_mux muxcs8_2
	ad_connect muxcs8_2/select_path logic_no_q1/Res

	#First input CS16 - > I0 -> I0
	ad_connect util_ad9361_adc_fifo/dout_data_2 muxcs8_2/data_in_0
	ad_connect util_ad9361_adc_fifo/dout_valid_2 muxcs8_2/valid_in_0
	ad_connect util_ad9361_adc_fifo/dout_enable_3 muxcs8_2/enable_in_0

	#Second input CS8 - > I0+Q0
	ad_connect rxcs22_cs8/combined_out muxcs8_2/data_in_1
	ad_connect util_ad9361_adc_fifo/dout_valid_2 muxcs8_2/valid_in_1
	ad_connect GND muxcs8_2/enable_in_1

	#OUT
	ad_connect util_ad9361_adc_fifo/dout_data_3 util_ad9361_adc_pack/fifo_wr_data_3
	ad_connect muxcs8_2/data_out util_ad9361_adc_pack/fifo_wr_data_2
	ad_connect muxcs8_2/enable_out util_ad9361_adc_pack/enable_3

	# ======================= 8BITS TX2 OUT  ============================
	# I PART
	ad_ip_instance xlslice shiftsliceitx2
	ad_ip_parameter shiftsliceitx2 CONFIG.DIN_WIDTH 16
	ad_ip_parameter shiftsliceitx2 CONFIG.DIN_FROM 15
	ad_ip_parameter shiftsliceitx2 CONFIG.DIN_TO 8
	ad_ip_parameter shiftsliceitx2 CONFIG.DOUT_WIDTH 8
	ad_connect util_ad9361_dac_upack/fifo_rd_data_2 shiftsliceitx2/Din

	ad_ip_instance xlconcat concatslicetx_i2

	ad_ip_parameter concatslicetx_i2 CONFIG.NUM_PORTS 3
	ad_ip_parameter concatslicetx_i2 CONFIG.IN0_WIDTH 4
	ad_ip_parameter concatslicetx_i2 CONFIG.IN1_WIDTH 8
	ad_ip_parameter concatslicetx_i2 CONFIG.IN2_WIDTH 4

	ad_connect shiftsliceitx2/Dout concatslicetx_i2/In1

	# Q PART
	ad_ip_instance xlslice shiftsliceqtx2
	ad_ip_parameter shiftsliceqtx2 CONFIG.DIN_WIDTH 16
	ad_ip_parameter shiftsliceqtx2 CONFIG.DIN_FROM 7
	ad_ip_parameter shiftsliceqtx2 CONFIG.DIN_TO 0
	ad_ip_parameter shiftsliceqtx2 CONFIG.DOUT_WIDTH 8
	ad_connect util_ad9361_dac_upack/fifo_rd_data_2 shiftsliceqtx2/Din

	ad_ip_instance xlconcat concatslicetx_q2
	ad_ip_parameter concatslicetx_q2 CONFIG.NUM_PORTS 3
	ad_ip_parameter concatslicetx_q2 CONFIG.IN0_WIDTH 4
	ad_ip_parameter concatslicetx_q2 CONFIG.IN1_WIDTH 8
	ad_ip_parameter concatslicetx_q2 CONFIG.IN2_WIDTH 4

	ad_connect shiftsliceqtx2/Dout concatslicetx_q2/In1

	ad_ip_instance util_vector_logic logic_no_q0_tx2 [list \
	  C_OPERATION {not} \
	  C_SIZE 1]
	ad_connect axi_ad9361_dac_fifo/din_enable_3 logic_no_q0_tx2/Op1


	#Select input depending on dac_qo_enable
	# *****  I PART **********
	create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_i2

	ad_connect muxcs8_tx_i2/select_path logic_no_q0_tx2/Res
	ad_connect muxcs8_tx_i2/enable_in_0 axi_ad9361_dac_fifo/din_enable_2
	#First input CS16 - > I0 -> I0
	ad_connect util_ad9361_dac_upack/fifo_rd_data_2 muxcs8_tx_i2/data_in_0
	#Second input C8 - > CS16 > I0
	ad_connect concatslicetx_i2/Dout muxcs8_tx_i2/data_in_1
	ad_connect muxcs8_tx_i2/enable_in_1 axi_ad9361_dac_fifo/din_enable_3

	#OUT
	#ad_connect muxcs8_tx_i2/data_out axi_ad9361_dac_fifo/din_data_2
	ad_connect muxcs8_tx_i2/enable_out util_ad9361_dac_upack/enable_2

	#Select input depending on dac_qo_enable
	# *****  Q PART **********
	create_bd_cell -type module -reference ad_bus_mux muxcs8_tx_q2

	ad_connect muxcs8_tx_q2/select_path logic_no_q0_tx2/Res
	ad_connect muxcs8_tx_q2/enable_in_0 axi_ad9361_dac_fifo/din_enable_3
	#First input CS16 - > I0 -> I0	
	ad_connect util_ad9361_dac_upack/fifo_rd_data_3 muxcs8_tx_q2/data_in_0
	#Second input C8 - > CS16 > I0
	ad_connect concatslicetx_q2/Dout muxcs8_tx_q2/data_in_1
	ad_connect muxcs8_tx_q2/enable_in_1 axi_ad9361_dac_fifo/din_enable_2

	#OUT
	#ad_connect muxcs8_tx_q2/data_out axi_ad9361_dac_fifo/din_data_3
	ad_connect muxcs8_tx_q2/enable_out util_ad9361_dac_upack/enable_3

