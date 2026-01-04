# enable E310 specific settings
set e310 "e310"
set maia_iio "maia_iio"
set with_tx_fir "with_tx_fir"
#set with_rx_fir "with_rx_fir"
set with_rx_fir_maia "with_rx_fir_maia"
source ../common/xilinx_init.tcl
source ../boards/e310/ps7.tcl
source ../boards/e310/ports.tcl
source ../common/xilinx_ad9361.tcl
source ../boards/e310/vcxo_ctrl.tcl

