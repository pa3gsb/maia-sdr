create_bd_port -dir I ad936x_sync

# fishball7010's pad_4/6/8/10/12/14/16_tx/18_rx GPIO expansion pads lived on
# Bank35 pins that this board's schematic repurposes for RGMII/CTRL_* signals
# (e.g. H16 = PHY_RXCLK here, vs. pad_12 on fishball7010) -- dropped for this
# initial bring-up rather than re-guessed; revisit once the extension I/O
# net names (CTRL_IN0-3/CTRL_OUT0-7 etc.) are mapped out.

# RGMII Ethernet PHY (RTL8211F), lands on PL pins on this board -> GEM0
# over EMIO + gmii_to_rgmii, same pattern as boards/plutoskyr2/ports.tcl

create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_PHY
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:rgmii_rtl:1.0 RGMII

ad_ip_instance gmii_to_rgmii sys_rgmii
ad_ip_parameter sys_rgmii CONFIG.SupportLevel Include_Shared_Logic_in_Core

ad_connect  sys_rgmii/tx_reset sys_rstgen/peripheral_reset
ad_connect  sys_rgmii/rx_reset sys_rstgen/peripheral_reset
ad_connect  sys_rgmii/clkin sys_ps7/FCLK_CLK1
ad_connect  sys_ps7/MDIO_ETHERNET_0 sys_rgmii/MDIO_GEM
ad_connect  sys_ps7/GMII_ETHERNET_0 sys_rgmii/GMII
ad_connect  sys_rgmii/MDIO_PHY MDIO_PHY
ad_connect  sys_rgmii/RGMII RGMII
