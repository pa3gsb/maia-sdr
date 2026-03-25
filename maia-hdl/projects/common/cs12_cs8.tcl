#First delete existing connections
#Fixme : assuming mux_decim is present 

ad_disconnect mux_decim_i/data_out util_ad9361_adc_pack/fifo_wr_data_0
ad_disconnect mux_decim_q/data_out util_ad9361_adc_pack/fifo_wr_data_1
ad_disconnect util_ad9361_adc_fifo/dout_data_2 util_ad9361_adc_pack/fifo_wr_data_2
ad_disconnect util_ad9361_adc_fifo/dout_data_3 util_ad9361_adc_pack/fifo_wr_data_3

ad_disconnect mux_decim_i/valid_out util_ad9361_adc_pack/fifo_wr_en


ad_disconnect mux_decim_i/enable_out util_ad9361_adc_pack/enable_0
ad_disconnect mux_decim_q/enable_out util_ad9361_adc_pack/enable_1

ad_disconnect util_ad9361_adc_fifo/dout_enable_2 util_ad9361_adc_pack/enable_2
ad_disconnect util_ad9361_adc_fifo/dout_enable_3 util_ad9361_adc_pack/enable_3



### CHANNEL 0 ###

create_bd_cell -type module -reference cs12_8mux cs12_8mux_chan0

#Inputs

ad_connect util_ad9361_adc_fifo/dout_enable_0 cs12_8mux_chan0/Enable0
ad_connect util_ad9361_adc_fifo/dout_enable_1 cs12_8mux_chan0/Enable1
ad_connect mux_decim_i/data_out cs12_8mux_chan0/I0
ad_connect mux_decim_q/data_out cs12_8mux_chan0/Q0

ad_connect mux_decim_i/valid_out cs12_8mux_chan0/valid_in
ad_connect cs12_8mux_chan0/clk util_ad9361_adc_fifo/dout_clk
ad_connect cs12_8mux_chan0/rst_n util_ad9361_adc_fifo/dout_rstn



#Outputs

ad_connect cs12_8mux_chan0/data_out0 util_ad9361_adc_pack/fifo_wr_data_0
ad_connect cs12_8mux_chan0/data_out1 util_ad9361_adc_pack/fifo_wr_data_1
ad_connect cs12_8mux_chan0/Enable_O1 util_ad9361_adc_pack/enable_0
ad_connect cs12_8mux_chan0/Enable_O2 util_ad9361_adc_pack/enable_1


### CHANNEL 1 ###

create_bd_cell -type module -reference cs12_8mux cs12_8mux_chan1

#Inputs

ad_connect util_ad9361_adc_fifo/dout_enable_2 cs12_8mux_chan1/Enable0
ad_connect util_ad9361_adc_fifo/dout_enable_3 cs12_8mux_chan1/Enable1
ad_connect util_ad9361_adc_fifo/dout_data_2 cs12_8mux_chan1/I0
ad_connect util_ad9361_adc_fifo/dout_data_3 cs12_8mux_chan1/Q0

ad_connect mux_decim_i/valid_out cs12_8mux_chan1/valid_in
ad_connect cs12_8mux_chan1/clk util_ad9361_adc_fifo/dout_clk
ad_connect cs12_8mux_chan1/rst_n util_ad9361_adc_fifo/dout_rstn


#Outputs

ad_connect cs12_8mux_chan1/data_out0 util_ad9361_adc_pack/fifo_wr_data_2
ad_connect cs12_8mux_chan1/data_out1 util_ad9361_adc_pack/fifo_wr_data_3
ad_connect cs12_8mux_chan1/Enable_O1 util_ad9361_adc_pack/enable_2
ad_connect cs12_8mux_chan1/Enable_O2 util_ad9361_adc_pack/enable_3

# OR BEETWEEN 2 CHANNELS
ad_ip_instance util_vector_logic channels_or [list \
	  C_OPERATION {or} \
	  C_SIZE 1]
ad_connect cs12_8mux_chan0/valid_out channels_or/Op1
ad_connect cs12_8mux_chan1/valid_out channels_or/Op2
ad_connect channels_or/Res util_ad9361_adc_pack/fifo_wr_en
