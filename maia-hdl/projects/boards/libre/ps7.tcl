ad_ip_instance processing_system7 sys_ps7

# ps7 settings
ad_ip_parameter sys_ps7 CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V}
ad_ip_parameter sys_ps7 CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 2.5V}
ad_ip_parameter sys_ps7 CONFIG.PCW_PACKAGE_NAME clg400
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_MIO_GPIO_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_ENET0_IO "MIO 16 .. 27"
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_GRP_MDIO_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_GRP_MDIO_IO "MIO 52 .. 53"
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET_RESET_SELECT "Separate reset pins"
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_RESET_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_ENET0_RESET_IO "MIO 46"
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP1 1
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_S_AXI_HP2 1
ad_ip_parameter sys_ps7 CONFIG.PCW_EN_CLK1_PORT 1
ad_ip_parameter sys_ps7 CONFIG.PCW_EN_RST1_PORT 1
ad_ip_parameter sys_ps7 CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ 100.0
ad_ip_parameter sys_ps7 CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ 200.0
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_EMIO_GPIO_IO 64
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH 64
ad_ip_parameter sys_ps7 CONFIG.PCW_SPI1_PERIPHERAL_ENABLE 0
ad_ip_parameter sys_ps7 CONFIG.PCW_I2C0_PERIPHERAL_ENABLE 0
ad_ip_parameter sys_ps7 CONFIG.PCW_UART1_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_UART1_UART1_IO {MIO 12 .. 13}
ad_ip_parameter sys_ps7 CONFIG.PCW_I2C1_PERIPHERAL_ENABLE 0
ad_ip_parameter sys_ps7 CONFIG.PCW_QSPI_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_SPI0_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_SPI0_SPI0_IO EMIO
ad_ip_parameter sys_ps7 CONFIG.PCW_USB0_PERIPHERAL_ENABLE 1

ad_ip_parameter sys_ps7 CONFIG.PCW_TTC0_PERIPHERAL_ENABLE 0
ad_ip_parameter sys_ps7 CONFIG.PCW_USE_FABRIC_INTERRUPT 1

ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_MIO_GPIO_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_GPIO_MIO_GPIO_IO MIO
ad_ip_parameter sys_ps7 CONFIG.PCW_USB0_RESET_IO {MIO 47}	
ad_ip_parameter sys_ps7 CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ 50
ad_ip_parameter sys_ps7 CONFIG.PCW_SD0_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ 50
ad_ip_parameter sys_ps7 CONFIG.PCW_UART0_PERIPHERAL_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15}
ad_ip_parameter sys_ps7 CONFIG.PCW_USB0_RESET_ENABLE 1
ad_ip_parameter sys_ps7 CONFIG.PCW_IRQ_F2P_INTR 1
ad_ip_parameter sys_ps7 CONFIG.PCW_IRQ_F2P_MODE REVERSE
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_0_PULLUP {enabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_9_PULLUP {enabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_10_PULLUP {enabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_11_PULLUP {enabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_48_PULLUP {enabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_49_PULLUP {disabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_MIO_53_PULLUP {enabled}


# CUSTOM MEMORY
ad_ip_parameter sys_ps7 CONFIG.PCW_APU_PERIPHERAL_FREQMHZ 750	
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_PARTNO {Custom}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT {3}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT {15}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT {10}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_CL {9}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_CWL {7}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_T_RCD {9}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_T_RP {9}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_T_RC {48.91}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN {35.0}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_T_FAW {40.0}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0 {0.048}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1 {0.050}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0 {0.241}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1 {0.240}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_ECC {Disabled}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1}
ad_ip_parameter sys_ps7 CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0}
