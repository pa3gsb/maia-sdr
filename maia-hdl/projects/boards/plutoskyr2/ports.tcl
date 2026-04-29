


create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_PHY
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:rgmii_rtl:1.0 RGMII

ad_ip_instance gmii_to_rgmii sys_rgmii
ad_ip_parameter sys_rgmii CONFIG.SupportLevel Include_Shared_Logic_in_Core

#ad_connect  eth_rst_n sys_rstgen/peripheral_aresetn
ad_connect  sys_rgmii/tx_reset sys_rstgen/peripheral_reset
ad_connect  sys_rgmii/rx_reset sys_rstgen/peripheral_reset
ad_connect  sys_rgmii/clkin sys_ps7/FCLK_CLK1 
ad_connect  sys_ps7/MDIO_ETHERNET_0 sys_rgmii/MDIO_GEM
ad_connect  sys_ps7/GMII_ETHERNET_0 sys_rgmii/GMII
ad_connect  sys_rgmii/MDIO_PHY MDIO_PHY
ad_connect  sys_rgmii/RGMII RGMII