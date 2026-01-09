# Get the directory where THIS script lives
set script_path [file normalize [file dirname [info script]]]

# Set a global variable so other scripts can see it
set ::tezuka_hdl_dir $script_path

# Optional: Set it in the OS environment so it's accessible everywhere
set ::env(TEZUKA_HDL_DIR) $script_path