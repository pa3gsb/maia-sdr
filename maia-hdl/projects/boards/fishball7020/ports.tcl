
create_bd_port -dir I pps
create_bd_port -dir I clk_10
create_bd_port -dir O phase
create_bd_port -dir I serial_rx
create_bd_port -dir O serial_tx
create_bd_port -dir O lock
create_bd_port -dir O -type clk outclk

# Declared unconditionally so system_top.v's named-port connections to these
# always elaborate, whether or not `spiquad` is set in system_bd.tcl. When
# spiquad.tcl runs it wires these to axi_quad_spi; otherwise system_bd.tcl
# ties the outputs off (see the spiquad conditional there).
create_bd_port -dir O qspi_csn_o
create_bd_port -dir I qspi_csn_i
create_bd_port -dir I qspi_clk_i
create_bd_port -dir O qspi_clk_o
create_bd_port -dir I qspi_sdo_i
create_bd_port -dir O qspi_sdo_o
create_bd_port -dir I qspi_sdi_i

