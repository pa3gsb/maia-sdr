# Setup IP Repositories
set_property ip_repo_paths {../common/antsdr-hdl ../common/libresdr-hdl ../../ip ../../adi-hdl/library} [current_fileset]
update_ip_catalog
source ../../adi-hdl/projects/common/xilinx/adi_fir_filter_bd.tcl

# Default Global Ports
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 ddr
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 fixed_io


#ps_7.tcl should be called after that