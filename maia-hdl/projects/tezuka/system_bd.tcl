if { [info exists ::env(PROJECT_NAME)] } {
  set project_name $::env(PROJECT_NAME)
} else {
  set project_name "e310"
}

# enable E310 specific settings
if { $project_name eq "e310" } {
  set e310 "e310"
}

source ../common/xilinx_init.tcl
source ../boards/$project_name/ps7.tcl
source ../boards/$project_name/ports.tcl
source ../common/xilinx_ad9361.tcl
source ../common/maia.tcl
source ../common/maiafirtoiq.tcl
#source ../common/minimal.tcl
source ../boards/$project_name/vcxo_ctrl.tcl
source ../common/sweeper.tcl
source ../common/cs12_cs8.tcl