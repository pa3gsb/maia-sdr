# SPI Ports (Standard for AD9361 EMIO)
create_bd_port -dir O spi0_csn_2_o
create_bd_port -dir O spi0_csn_1_o
create_bd_port -dir O spi0_csn_0_o
create_bd_port -dir I spi0_csn_i
create_bd_port -dir I spi0_clk_i
create_bd_port -dir O spi0_clk_o
create_bd_port -dir I spi0_sdo_i
create_bd_port -dir O spi0_sdo_o
create_bd_port -dir I spi0_sdi_i

# GPIO 

create_bd_port -dir I -from 63 -to 0 gpio_i
create_bd_port -dir O -from 63 -to 0 gpio_o
create_bd_port -dir O -from 63 -to 0 gpio_t

# Instantiate Processing System

ad_ip_instance xlconcat sys_concat_intc
ad_ip_parameter sys_concat_intc CONFIG.NUM_PORTS 16

ad_ip_instance proc_sys_reset sys_rstgen
ad_ip_parameter sys_rstgen CONFIG.C_EXT_RST_WIDTH 1

# Clock/Reset Interconnects
ad_connect  sys_cpu_clk sys_ps7/FCLK_CLK0
ad_connect  sys_200m_clk sys_ps7/FCLK_CLK1
ad_connect  sys_cpu_reset sys_rstgen/peripheral_reset
ad_connect  sys_cpu_resetn sys_rstgen/peripheral_aresetn
ad_connect  sys_cpu_clk sys_rstgen/slowest_sync_clk
ad_connect  sys_rstgen/ext_reset_in sys_ps7/FCLK_RESET0_N

# interface connections

ad_connect  ddr sys_ps7/DDR
ad_connect  gpio_i sys_ps7/GPIO_I
#Need to be disconnected on some designs
ad_connect  gpio_o sys_ps7/GPIO_O
ad_connect  gpio_t sys_ps7/GPIO_T
ad_connect  fixed_io sys_ps7/FIXED_IO

# ps7 spi connections

ad_connect  spi0_csn_2_o sys_ps7/SPI0_SS2_O
ad_connect  spi0_csn_1_o sys_ps7/SPI0_SS1_O
ad_connect  spi0_csn_0_o sys_ps7/SPI0_SS_O
ad_connect  spi0_csn_i sys_ps7/SPI0_SS_I
ad_connect  spi0_clk_i sys_ps7/SPI0_SCLK_I
ad_connect  spi0_clk_o sys_ps7/SPI0_SCLK_O
ad_connect  spi0_sdo_i sys_ps7/SPI0_MOSI_I
ad_connect  spi0_sdo_o sys_ps7/SPI0_MOSI_O
ad_connect  spi0_sdi_i sys_ps7/SPI0_MISO_I

# interrupts

ad_connect  sys_concat_intc/dout sys_ps7/IRQ_F2P
ad_connect  sys_concat_intc/In15 GND
ad_connect  sys_concat_intc/In14 GND
ad_connect  sys_concat_intc/In13 GND
ad_connect  sys_concat_intc/In12 GND
ad_connect  sys_concat_intc/In11 GND
ad_connect  sys_concat_intc/In10 GND
ad_connect  sys_concat_intc/In9 GND
ad_connect  sys_concat_intc/In8 GND
ad_connect  sys_concat_intc/In7 GND
ad_connect  sys_concat_intc/In6 GND
ad_connect  sys_concat_intc/In5 GND
ad_connect  sys_concat_intc/In4 GND
ad_connect  sys_concat_intc/In3 GND
ad_connect  sys_concat_intc/In2 GND
ad_connect  sys_concat_intc/In1 GND
ad_connect  sys_concat_intc/In0 GND

# Create ad9361 in/output pins
if {[info exists lvds]} {
create_bd_port -dir I rx_clk_in_p
create_bd_port -dir I rx_clk_in_n
create_bd_port -dir I rx_frame_in_p
create_bd_port -dir I rx_frame_in_n
create_bd_port -dir I -from 5 -to 0 rx_data_in_p
create_bd_port -dir I -from 5 -to 0 rx_data_in_n

create_bd_port -dir O tx_clk_out_p
create_bd_port -dir O tx_clk_out_n
create_bd_port -dir O tx_frame_out_p
create_bd_port -dir O tx_frame_out_n
create_bd_port -dir O -from 5 -to 0 tx_data_out_p
create_bd_port -dir O -from 5 -to 0 tx_data_out_n

} else {
create_bd_port -dir I rx_clk_in
create_bd_port -dir I rx_frame_in
create_bd_port -dir I -from 11 -to 0 rx_data_in

create_bd_port -dir O tx_clk_out
create_bd_port -dir O tx_frame_out
create_bd_port -dir O -from 11 -to 0 tx_data_out
}

create_bd_port -dir O enable
create_bd_port -dir O txnrx
create_bd_port -dir I up_enable
create_bd_port -dir I up_txnrx

# AD9361 INSTANCE

ad_ip_instance axi_ad9361 axi_ad9361
ad_ip_parameter axi_ad9361 CONFIG.ID 0

#AD9361 according to lvds/cmos
if {[info exists lvds] } {
ad_ip_parameter axi_ad9361 CONFIG.CMOS_OR_LVDS_N 0
ad_ip_parameter axi_ad9361 CONFIG.MODE_1R1T 0
ad_ip_parameter axi_ad9361 CONFIG.ADC_INIT_DELAY 30
} else {
ad_ip_parameter axi_ad9361 CONFIG.CMOS_OR_LVDS_N 1
ad_ip_parameter axi_ad9361 CONFIG.MODE_1R1T 0
ad_ip_parameter axi_ad9361 CONFIG.ADC_INIT_DELAY 21
}

# parameters to reduce size
ad_ip_parameter axi_ad9361 CONFIG.TDD_DISABLE 1

# FIFO LIKE FMCOMMS2
# https://github.com/analogdevicesinc/hdl/commit/bad4eb51a9397aab2a9a01b771b3cd181422e6f6
# https://wiki.analog.com/resources/eval/user-guides/ad-fmcomms2-ebz/interface_timing_validation
# interface clock divider to generate sampling clock
# interface runs at 4x in 2r2t mode, and 2x in 1r1t mode

ad_ip_instance xlconcat util_ad9361_divclk_sel_concat
ad_ip_parameter util_ad9361_divclk_sel_concat CONFIG.NUM_PORTS 2
ad_connect axi_ad9361/adc_r1_mode util_ad9361_divclk_sel_concat/In0
ad_connect axi_ad9361/dac_r1_mode util_ad9361_divclk_sel_concat/In1

ad_ip_instance util_reduced_logic util_ad9361_divclk_sel
ad_ip_parameter util_ad9361_divclk_sel CONFIG.C_SIZE 2

ad_connect util_ad9361_divclk_sel_concat/dout util_ad9361_divclk_sel/Op1

ad_ip_instance util_clkdiv util_ad9361_divclk
if {[info exists lvds]} {
ad_ip_parameter util_ad9361_divclk CONFIG.SEL_0_DIV 4
ad_ip_parameter util_ad9361_divclk CONFIG.SEL_1_DIV 2
} else {
ad_ip_parameter util_ad9361_divclk CONFIG.SEL_0_DIV 2
ad_ip_parameter util_ad9361_divclk CONFIG.SEL_1_DIV 1
}

ad_connect util_ad9361_divclk_sel/Res util_ad9361_divclk/clk_sel
ad_connect axi_ad9361/l_clk util_ad9361_divclk/clk

# resets at divided clock

ad_ip_instance proc_sys_reset util_ad9361_divclk_reset
ad_connect sys_rstgen/peripheral_aresetn util_ad9361_divclk_reset/ext_reset_in
ad_connect util_ad9361_divclk/clk_out util_ad9361_divclk_reset/slowest_sync_clk

# adc-path wfifo

ad_ip_instance util_wfifo util_ad9361_adc_fifo
ad_ip_parameter util_ad9361_adc_fifo CONFIG.NUM_OF_CHANNELS 4
ad_ip_parameter util_ad9361_adc_fifo CONFIG.DIN_ADDRESS_WIDTH 4
ad_ip_parameter util_ad9361_adc_fifo CONFIG.DIN_DATA_WIDTH 16
ad_ip_parameter util_ad9361_adc_fifo CONFIG.DOUT_DATA_WIDTH 16
ad_connect axi_ad9361/l_clk util_ad9361_adc_fifo/din_clk
ad_connect axi_ad9361/rst util_ad9361_adc_fifo/din_rst
ad_connect util_ad9361_divclk/clk_out util_ad9361_adc_fifo/dout_clk
ad_connect util_ad9361_divclk_reset/peripheral_aresetn util_ad9361_adc_fifo/dout_rstn
ad_connect axi_ad9361/adc_enable_i0 util_ad9361_adc_fifo/din_enable_0
ad_connect axi_ad9361/adc_valid_i0 util_ad9361_adc_fifo/din_valid_0
ad_connect axi_ad9361/adc_data_i0 util_ad9361_adc_fifo/din_data_0
ad_connect axi_ad9361/adc_enable_q0 util_ad9361_adc_fifo/din_enable_1
ad_connect axi_ad9361/adc_valid_q0 util_ad9361_adc_fifo/din_valid_1
ad_connect axi_ad9361/adc_data_q0 util_ad9361_adc_fifo/din_data_1
ad_connect axi_ad9361/adc_enable_i1 util_ad9361_adc_fifo/din_enable_2
ad_connect axi_ad9361/adc_valid_i1 util_ad9361_adc_fifo/din_valid_2
ad_connect axi_ad9361/adc_data_i1 util_ad9361_adc_fifo/din_data_2
ad_connect axi_ad9361/adc_enable_q1 util_ad9361_adc_fifo/din_enable_3
ad_connect axi_ad9361/adc_valid_q1 util_ad9361_adc_fifo/din_valid_3
ad_connect axi_ad9361/adc_data_q1 util_ad9361_adc_fifo/din_data_3
ad_connect util_ad9361_adc_fifo/din_ovf axi_ad9361/adc_dovf

# dac-path rfifo

ad_ip_instance util_rfifo axi_ad9361_dac_fifo
ad_ip_parameter axi_ad9361_dac_fifo CONFIG.DIN_DATA_WIDTH 16
ad_ip_parameter axi_ad9361_dac_fifo CONFIG.DOUT_DATA_WIDTH 16
ad_ip_parameter axi_ad9361_dac_fifo CONFIG.DIN_ADDRESS_WIDTH 4
ad_connect axi_ad9361/l_clk axi_ad9361_dac_fifo/dout_clk
ad_connect axi_ad9361/rst axi_ad9361_dac_fifo/dout_rst
ad_connect util_ad9361_divclk/clk_out axi_ad9361_dac_fifo/din_clk
ad_connect util_ad9361_divclk_reset/peripheral_aresetn axi_ad9361_dac_fifo/din_rstn
ad_connect axi_ad9361_dac_fifo/dout_enable_0 axi_ad9361/dac_enable_i0
ad_connect axi_ad9361_dac_fifo/dout_valid_0 axi_ad9361/dac_valid_i0
ad_connect axi_ad9361_dac_fifo/dout_data_0 axi_ad9361/dac_data_i0
ad_connect axi_ad9361_dac_fifo/dout_enable_1 axi_ad9361/dac_enable_q0
ad_connect axi_ad9361_dac_fifo/dout_valid_1 axi_ad9361/dac_valid_q0
ad_connect axi_ad9361_dac_fifo/dout_data_1 axi_ad9361/dac_data_q0
ad_connect axi_ad9361_dac_fifo/dout_enable_2 axi_ad9361/dac_enable_i1
ad_connect axi_ad9361_dac_fifo/dout_valid_2 axi_ad9361/dac_valid_i1
ad_connect axi_ad9361_dac_fifo/dout_data_2 axi_ad9361/dac_data_i1
ad_connect axi_ad9361_dac_fifo/dout_enable_3 axi_ad9361/dac_enable_q1
ad_connect axi_ad9361_dac_fifo/dout_valid_3 axi_ad9361/dac_valid_q1
ad_connect axi_ad9361_dac_fifo/dout_data_3 axi_ad9361/dac_data_q1
ad_connect axi_ad9361_dac_fifo/dout_unf axi_ad9361/dac_dunf

# connections ad9361 in/output pins
if {[info exists lvds] } {
ad_connect  rx_clk_in_p axi_ad9361/rx_clk_in_p
ad_connect  rx_clk_in_n axi_ad9361/rx_clk_in_n
ad_connect  rx_frame_in_p axi_ad9361/rx_frame_in_p
ad_connect  rx_frame_in_n axi_ad9361/rx_frame_in_n
ad_connect  rx_data_in_p axi_ad9361/rx_data_in_p
ad_connect  rx_data_in_n axi_ad9361/rx_data_in_n
ad_connect  tx_clk_out_p axi_ad9361/tx_clk_out_p
ad_connect  tx_clk_out_n axi_ad9361/tx_clk_out_n
ad_connect  tx_frame_out_p axi_ad9361/tx_frame_out_p
ad_connect  tx_frame_out_n axi_ad9361/tx_frame_out_n
ad_connect  tx_data_out_p axi_ad9361/tx_data_out_p
ad_connect  tx_data_out_n axi_ad9361/tx_data_out_n
} else {
ad_connect  rx_clk_in axi_ad9361/rx_clk_in
ad_connect  rx_frame_in axi_ad9361/rx_frame_in
ad_connect  rx_data_in axi_ad9361/rx_data_in
ad_connect  tx_clk_out axi_ad9361/tx_clk_out
ad_connect  tx_frame_out axi_ad9361/tx_frame_out
ad_connect  tx_data_out axi_ad9361/tx_data_out
}

ad_connect  enable axi_ad9361/enable
ad_connect  txnrx axi_ad9361/txnrx
ad_connect  up_enable axi_ad9361/up_enable
ad_connect  up_txnrx axi_ad9361/up_txnrx

ad_connect  axi_ad9361/tdd_sync GND
ad_connect  sys_200m_clk axi_ad9361/delay_clk
ad_connect  axi_ad9361/l_clk axi_ad9361/clk

# DAC_DMA

ad_ip_instance axi_dmac axi_ad9361_dac_dma
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_TYPE_SRC 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_TYPE_DEST 1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.CYCLIC 1
ad_ip_parameter axi_ad9361_dac_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter axi_ad9361_dac_dma CONFIG.DMA_DATA_WIDTH_DEST 64

# DAC UPACK 

ad_ip_instance util_upack2 util_ad9361_dac_upack { \
  		NUM_OF_CHANNELS 4 \
  		SAMPLE_DATA_WIDTH 16 \
}


# Connections ot DAC_FIFO TO DAC_UPACK


	for {set i 0} {$i < 4} {incr i} {
    #Direct connection : should be unconnected for tezuka
    ad_connect util_ad9361_dac_upack/enable_$i axi_ad9361_dac_fifo/din_enable_$i
    ad_connect util_ad9361_dac_upack/fifo_rd_valid axi_ad9361_dac_fifo/din_valid_in_$i
    #Direct connection : should be unconnected for tezuka
    ad_connect util_ad9361_dac_upack/fifo_rd_data_$i axi_ad9361_dac_fifo/din_data_$i
    }
	
    ad_connect util_ad9361_divclk/clk_out util_ad9361_dac_upack/clk
	ad_connect util_ad9361_divclk_reset/peripheral_reset util_ad9361_dac_upack/reset
    ad_connect util_ad9361_divclk/clk_out axi_ad9361_dac_dma/m_axis_aclk
	ad_connect util_ad9361_dac_upack/s_axis  axi_ad9361_dac_dma/m_axis

	ad_ip_instance util_vector_logic logic_or [list \
	  C_OPERATION {or} \
	  C_SIZE 1]
	ad_connect axi_ad9361_dac_fifo/dout_valid_out_0 util_ad9361_dac_upack/fifo_rd_en
	ad_connect util_ad9361_dac_upack/fifo_rd_underflow axi_ad9361_dac_fifo/din_unf
    


# ADC DMA

	ad_ip_instance axi_dmac axi_ad9361_adc_dma
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_TYPE_SRC 2
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_TYPE_DEST 0
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.CYCLIC 0
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.SYNC_TRANSFER_START 0
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.AXI_SLICE_SRC 0
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.AXI_SLICE_DEST 0
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_2D_TRANSFER 0
	ad_ip_parameter axi_ad9361_adc_dma CONFIG.DMA_DATA_WIDTH_SRC 64

	ad_ip_instance util_cpack2 util_ad9361_adc_pack { \
  NUM_OF_CHANNELS 4 \
  SAMPLE_DATA_WIDTH 16 \
}

# Connections ot ADC_FIFO TO ADC_UPACK
# Direct connection : should be unconnected for tezuka

 for {set i 0} {$i < 4} {incr i} {
  ad_connect util_ad9361_adc_fifo/dout_enable_$i util_ad9361_adc_pack/enable_$i
  ad_connect util_ad9361_adc_fifo/dout_data_$i util_ad9361_adc_pack/fifo_wr_data_$i
 }

# Connections ot FIFO ADC
ad_connect axi_ad9361_adc_dma/fifo_wr util_ad9361_adc_pack/packed_fifo_wr	

ad_connect util_ad9361_divclk/clk_out util_ad9361_adc_pack/clk
ad_connect util_ad9361_divclk_reset/peripheral_reset util_ad9361_adc_pack/reset
ad_connect util_ad9361_adc_pack/fifo_wr_overflow util_ad9361_adc_fifo/dout_ovf
ad_connect util_ad9361_adc_pack/fifo_wr_en util_ad9361_adc_fifo/dout_valid_0
ad_connect  util_ad9361_divclk/clk_out axi_ad9361_adc_dma/fifo_wr_clk


# interconnects

ad_cpu_interconnect 0x79020000 axi_ad9361
ad_cpu_interconnect 0x7C400000 axi_ad9361_adc_dma
ad_cpu_interconnect 0x7C420000 axi_ad9361_dac_dma

ad_connect sys_cpu_clk axi_ad9361_dac_dma/m_src_axi_aclk
ad_connect sys_cpu_clk axi_ad9361_adc_dma/m_dest_axi_aclk
ad_connect sys_cpu_resetn axi_ad9361_adc_dma/m_dest_axi_aresetn
ad_connect sys_cpu_resetn axi_ad9361_dac_dma/m_src_axi_aresetn

# interrupts

ad_cpu_interrupt ps-13 mb-13 axi_ad9361_adc_dma/irq
ad_cpu_interrupt ps-12 mb-12 axi_ad9361_dac_dma/irq


