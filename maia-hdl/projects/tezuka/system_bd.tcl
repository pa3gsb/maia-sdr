switch -glob -- $project_name {
    "e310" 
    {
        set vctcxo "vctcxo"
        set txfir "txfir"
        set dac_dds "dac_dds"
    }
    "e200" 
    {
        set vctcxo "vctcxo"
        set txfir "txfir"
        set dac_dds "dac_dds"
    }
    "libre" {
        set lvds "lvds"
        set vctcxo "vctcxo"
        set txfir "txfir"
        set dac_dds "dac_dds"
    }
    "pluto" {
        
       
    }
    "plutoplus" {
        
    }
    "fishball7010" {
        set lvds "lvds"
        #set uartlite "uartlite"
        
        
            }     
     
    "fishball7020" {
        set lvds "lvds"
        set uartlite "uartlite"
        set dac_dds "dac_dds"
        #set vctcxo "vctcxo"
        #set txfir "txfir"
        #set sync "sync"
        #set iqburst "iqburst"

    }
    "signalsdrpro" {
        set txfir "txfir"
        set dac_dds "dac_dds"
    }
    "nano" {
        
    }
    "plutoskyr2" {
       set lvds "lvds"
       set txfir "txfir" 
       set dac_dds "dac_dds"
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
if {[info exists txfir]} { source $::tezuka_hdl_dir/common/txfir.tcl }
if {[info exists sync]} { source $::tezuka_hdl_dir/common/sync.tcl }
if {[info exists iqburst]} { source $::tezuka_hdl_dir/common/iqburst.tcl }
