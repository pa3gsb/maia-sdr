ad_disconnect util_ad9361_dac_upack/enable_0 axi_ad9361_dac_fifo/din_enable_0
ad_disconnect util_ad9361_dac_upack/enable_1 axi_ad9361_dac_fifo/din_enable_1
ad_disconnect axi_ad9361_dac_fifo/din_valid_0 util_ad9361_dac_upack/fifo_rd_en
ad_disconnect util_ad9361_dac_upack/fifo_rd_data_0 axi_ad9361_dac_fifo/din_data_0
ad_disconnect util_ad9361_dac_upack/fifo_rd_data_1 axi_ad9361_dac_fifo/din_data_1
#ad_disconnect util_ad9361_dac_upack/fifo_rd_valid axi_ad9361_dac_fifo/din_valid_in_0


ad_add_interpolation_filter "tx_fir_interpolator_1" 8 2 1 {61.44} {7.68} \
                    "$::tezuka_hdl_dir/common/filter8_coeffs.coe"

ad_add_interpolation_filter "tx_fir_interpolator_2" 4 2 1 {7.68} {1.92} \
                    "$::tezuka_hdl_dir/common/filter4_coeffs.coe"

ad_ip_instance xlslice interp8_slice

ad_ip_instance xlslice interp4_slice
ad_ip_parameter interp4_slice CONFIG.DIN_FROM 1
ad_ip_parameter interp4_slice CONFIG.DIN_TO 1

# Clock for both stages
ad_connect util_ad9361_divclk/clk_out tx_fir_interpolator_1/aclk
ad_connect util_ad9361_divclk/clk_out tx_fir_interpolator_2/aclk

# Stage 2 (4x, closest to unpacker) — input from DAC unpacker
ad_connect util_ad9361_dac_upack/enable_0 tx_fir_interpolator_2/enable_out_0
ad_connect util_ad9361_dac_upack/enable_1 tx_fir_interpolator_2/enable_out_1
ad_connect util_ad9361_dac_upack/fifo_rd_en tx_fir_interpolator_2/valid_out_0
ad_connect util_ad9361_dac_upack/fifo_rd_data_0 tx_fir_interpolator_2/data_in_0
ad_connect util_ad9361_dac_upack/fifo_rd_data_1 tx_fir_interpolator_2/data_in_1

# Stage 2 (4x) -> Stage 1 (8x)
ad_connect tx_fir_interpolator_2/dac_enable_0 tx_fir_interpolator_1/enable_out_0
ad_connect tx_fir_interpolator_2/dac_enable_1 tx_fir_interpolator_1/enable_out_1
ad_connect tx_fir_interpolator_2/dac_valid_0 tx_fir_interpolator_1/valid_out_0
ad_connect tx_fir_interpolator_2/dac_valid_1 tx_fir_interpolator_1/valid_out_1
ad_connect tx_fir_interpolator_2/data_out_0 tx_fir_interpolator_1/data_in_0
ad_connect tx_fir_interpolator_2/data_out_1 tx_fir_interpolator_1/data_in_1

# Stage 1 (8x) -> DAC FIFO
ad_connect tx_fir_interpolator_1/dac_enable_0 axi_ad9361_dac_fifo/din_enable_0
ad_connect tx_fir_interpolator_1/dac_enable_1 axi_ad9361_dac_fifo/din_enable_1
ad_connect axi_ad9361_dac_fifo/din_data_0 tx_fir_interpolator_1/data_out_0
ad_connect axi_ad9361_dac_fifo/din_data_1 tx_fir_interpolator_1/data_out_1
ad_connect axi_ad9361_dac_fifo/din_valid_0 tx_fir_interpolator_1/dac_valid_0
ad_connect axi_ad9361_dac_fifo/din_valid_1 tx_fir_interpolator_1/dac_valid_1

# GPIO control slice
ad_connect axi_ad9361/up_dac_gpio_out interp8_slice/Din
ad_connect tx_fir_interpolator_1/active interp8_slice/Dout
ad_connect axi_ad9361/up_dac_gpio_out interp4_slice/Din
ad_connect tx_fir_interpolator_2/active interp4_slice/Dout
