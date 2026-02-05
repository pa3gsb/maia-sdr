switch -glob -- $project_name {
    "e310" 
    {
        set vctcxo "vctcxo"
    }
    "e200" 
    {
        set vctcxo "vctcxo"
    }
    "libre" {
        set lvds "lvds"
        set vctcxo "vctcxo"
    }
    "pluto" {
        
       
    }
    "plutoplus" {
        
    }
    "fishball7010" {
        set lvds "lvds"
            }     
    "fishball7020" {
        set lvds "lvds"
        set uartlite "uartlite"
        set vctcxo "vctcxo"
        set fftraw "fftraw"
    }
    "signalsdrpro" {
        
    }
    "nano" {
        
    }
    default {
        puts "CRITICAL WARNING: Project name '$project_name' not recognized."
        exit 1
    }
}


source $::tezuka_hdl_dir/common/xilinx_init.tcl
source $::tezuka_hdl_dir/boards/$project_name/ps7.tcl
source $::tezuka_hdl_dir/common/xilinx_ad9361.tcl
source $::tezuka_hdl_dir/boards/$project_name/ports.tcl
#source $::tezuka_hdl_dir/common/minimal.tcl
source $::tezuka_hdl_dir/common/maia.tcl
if {[info exists fftraw]} {
      source $::tezuka_hdl_dir/common/maiaffttoiq.tcl
} else {
   source $::tezuka_hdl_dir/common/maiafirtoiq.tcl
}



if {[info exists vctcxo]} { source $::tezuka_hdl_dir/boards/$project_name/vcxo_ctrl.tcl }
source $::tezuka_hdl_dir/common/sweeper.tcl
source $::tezuka_hdl_dir/common/cs12_cs8.tcl
if {[info exists uartlite]} { source $::tezuka_hdl_dir/common/uartlite.tcl }
#source $::tezuka_hdl_dir/common/txfir.tcl