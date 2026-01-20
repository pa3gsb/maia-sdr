# Setup IP Repositories
set_property ip_repo_paths [list \
  "$::tezuka_hdl_dir/common/antsdr-hdl" \
  "$::tezuka_hdl_dir/common/libresdr-hdl" \
  "$::tezuka_hdl_dir/../ip" \
  "$ad_hdl_dir/library" \
] [current_fileset]
update_ip_catalog
source $ad_hdl_dir/projects/common/xilinx/adi_fir_filter_bd.tcl

# Default Global Ports
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 ddr
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 fixed_io

add_files -norecurse  $ad_hdl_dir/library/common/ad_bus_mux.v
add_files -norecurse  $::tezuka_hdl_dir/common/sweeper_it.v
add_files -norecurse  $::tezuka_hdl_dir/common/cs12_cs8mux.v
add_files -norecurse  $::tezuka_hdl_dir/boards/fishball7020/vcxo_ctrl.v
#ps_7.tcl should be called after that