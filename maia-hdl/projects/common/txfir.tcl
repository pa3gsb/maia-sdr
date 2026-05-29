
ad_disconnect axi_ad9361_dac_fifo/din_valid_0 util_ad9361_dac_upack/fifo_rd_en
ad_disconnect util_ad9361_dac_upack/fifo_rd_data_0 axi_ad9361_dac_fifo/din_data_0
ad_disconnect util_ad9361_dac_upack/fifo_rd_data_1 axi_ad9361_dac_fifo/din_data_1


ad_add_interpolation_filter "tx_fir_interpolator" 8 2 1 {61.44} {7.68} \
                    "$::tezuka_hdl_dir/common/interpolator_x8.coe"



ad_connect util_ad9361_divclk/clk_out tx_fir_interpolator/aclk


ad_connect axi_ad9361_dac_fifo/din_data_0 tx_fir_interpolator/data_out_0
ad_connect axi_ad9361_dac_fifo/din_data_1 tx_fir_interpolator/data_out_1
ad_connect axi_ad9361_dac_fifo/din_valid_0 tx_fir_interpolator/dac_valid_0
ad_connect axi_ad9361_dac_fifo/din_valid_1 tx_fir_interpolator/dac_valid_1


ad_connect util_ad9361_dac_upack/fifo_rd_data_0 tx_fir_interpolator/data_in_0
ad_connect util_ad9361_dac_upack/fifo_rd_data_1 tx_fir_interpolator/data_in_1


ad_ip_instance xlslice interp8_slice
ad_ip_parameter interp8_slice CONFIG.DIN_FROM 0
ad_ip_parameter interp8_slice CONFIG.DIN_TO 0
ad_connect axi_ad9361/up_dac_gpio_out interp8_slice/Din
ad_connect  tx_fir_interpolator/active interp8_slice/Dout



#ad_connect util_ad9361_dac_upack/fifo_rd_en tx_fir_interpolator/valid_out_0 

#ad_ip_instance util_vector_logic logic_or [list C_OPERATION {or} C_SIZE 1]
#ad_connect logic_or/Op1 tx_fir_interpolator/valid_out_0
#ad_connect logic_or/Op2 axi_ad9361_dac_fifo/din_valid_0
#ad_connect logic_or/Res util_ad9361_dac_upack/fifo_rd_en

# ==============================================================================
# CORRECTION : LATENCE INTERNE APRÈS LES PORTES ET (DANS tx_fir_interpolator)
# ==============================================================================

# --- CANAL 0 (Voie I) ---
# 1. Instanciation du shift_ram pour le tvalid du Canal 0
ad_ip_instance c_shift_ram tx_fir_interpolator/delay_tvalid_0
set_property -dict [list CONFIG.Width {1} CONFIG.Depth {2}] [get_bd_cells tx_fir_interpolator/delay_tvalid_0]
ad_connect util_ad9361_divclk/clk_out tx_fir_interpolator/delay_tvalid_0/CLK

# 2. Déconnexion de la liaison native entre la porte ET et le FIR Compiler 0
ad_disconnect tx_fir_interpolator/logic_and_0/Res tx_fir_interpolator/fir_interpolation_0/s_axis_data_tvalid

# 3. Insertion du shift_ram au milieu
ad_connect tx_fir_interpolator/logic_and_0/Res tx_fir_interpolator/delay_tvalid_0/D
ad_connect tx_fir_interpolator/delay_tvalid_0/Q tx_fir_interpolator/fir_interpolation_0/s_axis_data_tvalid


# --- CANAL 1 (Voie Q) ---
# 1. Instanciation du shift_ram pour le tvalid du Canal 1
ad_ip_instance c_shift_ram tx_fir_interpolator/delay_tvalid_1
set_property -dict [list CONFIG.Width {1} CONFIG.Depth {2}] [get_bd_cells tx_fir_interpolator/delay_tvalid_1]
ad_connect util_ad9361_divclk/clk_out tx_fir_interpolator/delay_tvalid_1/CLK

# 2. Déconnexion de la liaison native entre la porte ET et le FIR Compiler 1
ad_disconnect tx_fir_interpolator/logic_and_1/Res tx_fir_interpolator/fir_interpolation_1/s_axis_data_tvalid

# 3. Insertion du shift_ram au milieu
ad_connect tx_fir_interpolator/logic_and_1/Res tx_fir_interpolator/delay_tvalid_1/D
ad_connect tx_fir_interpolator/delay_tvalid_1/Q tx_fir_interpolator/fir_interpolation_1/s_axis_data_tvalid


# ==============================================================================
# CORRECTION DU CÂBLAGE DE VALIDATION DU FIFO DAC (AFFECTATION DES VOIES I ET Q)
# ==============================================================================

# 1. Déconnexion des liaisons natives qui bridaient l'écriture dans le FIFO
ad_disconnect util_ad9361_dac_upack/fifo_rd_valid axi_ad9361_dac_fifo/din_valid_in_0
ad_disconnect util_ad9361_dac_upack/fifo_rd_valid axi_ad9361_dac_fifo/din_valid_in_1

# 2. Instanciation d'une porte OR pour basculer dynamiquement le comportement du valid
ad_ip_instance util_vector_logic dac_fifo_valid_or [list C_OPERATION {or} C_SIZE 1]

# 3. Connexion des entrées de la porte OR
# Op1 reçoit le valid de l'unpacker (utilisé en mode bypass)
ad_connect util_ad9361_dac_upack/fifo_rd_valid dac_fifo_valid_or/Op1
# Op2 reçoit le signal de contrôle 'active' (interp8_slice/Dout) pour forcer le valid à 1 en mode FIR
ad_connect interp8_slice/Dout dac_fifo_valid_or/Op2

# 4. Connexion de la sortie de la porte OR vers les entrées de validation du FIFO
ad_connect dac_fifo_valid_or/Res axi_ad9361_dac_fifo/din_valid_in_0
ad_connect dac_fifo_valid_or/Res axi_ad9361_dac_fifo/din_valid_in_1

