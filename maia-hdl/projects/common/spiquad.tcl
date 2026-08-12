ad_ip_instance axi_quad_spi axi_spi
ad_ip_parameter axi_spi CONFIG.C_USE_STARTUP 0
ad_ip_parameter axi_spi CONFIG.C_NUM_SS_BITS 1
ad_ip_parameter axi_spi CONFIG.C_SCK_RATIO 8

# qspi_* ports are declared unconditionally in boards/$project_name/ports.tcl
# (not here), so this file only has to wire them up.

# axi spi connections

ad_connect  sys_cpu_clk  axi_spi/ext_spi_clk
ad_connect  qspi_csn_i  axi_spi/ss_i
ad_connect  qspi_csn_o  axi_spi/ss_o
ad_connect  qspi_clk_i  axi_spi/sck_i
ad_connect  qspi_clk_o  axi_spi/sck_o
ad_connect  qspi_sdo_i  axi_spi/io0_i
ad_connect  qspi_sdo_o  axi_spi/io0_o
ad_connect  qspi_sdi_i  axi_spi/io1_i

ad_cpu_interconnect 0x7C430000 axi_spi

# interrupts
ad_cpu_interrupt ps-10 mb-10 axi_spi/ip2intc_irpt