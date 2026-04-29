#!/bin/bash

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 BASE_CLK CPU_CLK MEM_CLK"
    echo "  BASE_CLK : reference input clock in MHz"
    echo "  CPU_CLK  : desired CPU frequency in MHz"
    echo "  MEM_CLK  : desired DDR frequency in MHz"
    echo "  CPU_MULT = CPU_CLK * 2 / BASE_CLK"
    echo "  DDR_MULT = MEM_CLK * 2 / BASE_CLK"
    echo "Example: $0 50 1000 700"
    exit 1
fi

base_clk=$1
cpu_clk=$2
mem_clk=$3

# Validate all three inputs are positive integers
for var_name in base_clk cpu_clk mem_clk; do
    val="${!var_name}"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -le 0 ]; then
        echo "${var_name} value '${val}' is invalid. Must be a positive integer."
        exit 2
    fi
done

# Compute multipliers (integer division)
new_cpu_mult=$(( cpu_clk * 2 / base_clk ))
new_ddr_mult=$(( mem_clk * 2 / base_clk ))

# Validate computed multipliers are in range
if [ "$new_cpu_mult" -ge 128 ] || [ "$new_cpu_mult" -le 0 ]; then
    echo "Computed CPU multiplier ${new_cpu_mult} is out of range. Must be >0 and <128."
    exit 3
fi

if [ "$new_ddr_mult" -ge 128 ] || [ "$new_ddr_mult" -le 0 ]; then
    echo "Computed DDR multiplier ${new_ddr_mult} is out of range. Must be >0 and <128."
    exit 4
fi

SDK_PATH="build/sdk/fsbl"
PS7_INIT_FILE="${SDK_PATH}/src/ps7_init.c"

if [ ! -f "${PS7_INIT_FILE}" ]; then
    echo "${PS7_INIT_FILE} not found!"
    exit 5
fi

cpu_mult_template='EMIT_MASKWRITE\(0XF8000100, 0x0007F000U ,0x000XX000U\),'
cpu_mult_find='\s'"${cpu_mult_template/XX/(..)}"
ddr_mult_template='EMIT_MASKWRITE\(0XF8000104, 0x0007F000U ,0x000XX000U\),'
ddr_mult_find='\s'"${ddr_mult_template/XX/(..)}"

current_cpu_mult_hex=$(head -n 1 <<< $(sed -rn 's/'"${cpu_mult_find}"'/\1/p' "$PS7_INIT_FILE"))
current_ddr_mult_hex=$(head -n 1 <<< $(sed -rn 's/'"${ddr_mult_find}"'/\1/p' "$PS7_INIT_FILE"))

current_cpu_mult=$(echo "ibase=16; ${current_cpu_mult_hex}" | bc)
current_ddr_mult=$(echo "ibase=16; ${current_ddr_mult_hex}" | bc)

echo "Base clock      : ${base_clk} MHz"
echo "CPU: ${cpu_clk} MHz -> multiplier ${current_cpu_mult} -> ${new_cpu_mult}"
echo "DDR: ${mem_clk} MHz -> multiplier ${current_ddr_mult} -> ${new_ddr_mult}"

new_cpu_mult_hex=$(printf "%02X" $new_cpu_mult)
cpu_mult_replace="    ${cpu_mult_template/XX/${new_cpu_mult_hex}}"
new_ddr_mult_hex=$(printf "%02X" $new_ddr_mult)
ddr_mult_replace="    ${ddr_mult_template/XX/${new_ddr_mult_hex}}"

sed -i -r 's/'"${cpu_mult_find}"'/'"${cpu_mult_replace}"'/g' "$PS7_INIT_FILE"
sed -i -r 's/'"${ddr_mult_find}"'/'"${ddr_mult_replace}"'/g' "$PS7_INIT_FILE"

pushd "$SDK_PATH/Release"
make clean
make

if [ ! -f fsbl.elf ]; then
    echo "Build failed: fsbl.elf not produced."
    popd
    exit 6
fi

mv fsbl.elf "fsbl_CPU${cpu_clk}_DDR${mem_clk}.elf"
popd
