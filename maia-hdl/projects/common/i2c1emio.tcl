# PS7 I2C1 routed via EMIO (fishball7020 only). Requires
# CONFIG.PCW_I2C1_PERIPHERAL_ENABLE 1 / CONFIG.PCW_I2C1_I2C1_IO EMIO in
# boards/$project_name/ps7.tcl. scl/sda are wired to physical pads in
# system_top.v via an ad_iobuf instance (open-drain, mirrors the existing
# gpio_o/gpio_t/gpio_i iobuf pattern there).

create_bd_port -dir O i2c1_scl_o
create_bd_port -dir I i2c1_scl_i
create_bd_port -dir O i2c1_scl_t
create_bd_port -dir O i2c1_sda_o
create_bd_port -dir I i2c1_sda_i
create_bd_port -dir O i2c1_sda_t

ad_connect  i2c1_scl_o sys_ps7/I2C1_SCL_O
ad_connect  i2c1_scl_i sys_ps7/I2C1_SCL_I
ad_connect  i2c1_scl_t sys_ps7/I2C1_SCL_T
ad_connect  i2c1_sda_o sys_ps7/I2C1_SDA_O
ad_connect  i2c1_sda_i sys_ps7/I2C1_SDA_I
ad_connect  i2c1_sda_t sys_ps7/I2C1_SDA_T
