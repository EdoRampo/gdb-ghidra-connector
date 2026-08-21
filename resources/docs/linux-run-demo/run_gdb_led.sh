# !/bin/bash

# default config
MODE=gdb
while getopts "m:h" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        h) echo "用法: $0 -m <gdb|ghidra>"; exit 0 ;;
        *) exit 1 ;;
    esac
done

# run the selected frontend
if [[ "$MODE" == "gdb" ]]
then
    ./src/gdb_connect.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf -p 1234
elif [[ "$MODE" == "ghidra" ]]
then
    ./src/gdb_ghidra_connect.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf -p 1234 \
    -g /mnt/d/PROGRAM/reverse/ghidra_12.0.4_PUBLIC -G auto:18932 -V .venv
    # 172.25.112.1:18932
else
    echo "invalid mode: $MODE, please choose gdb or ghidra"
    exit 1
fi