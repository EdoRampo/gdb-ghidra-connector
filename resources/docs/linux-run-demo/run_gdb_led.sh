# !/bin/bash

# default config
MODE=gdb
BACKEND_HOST=localhost
BACKEND_PORT=1234
GHIDRA_PORT=18932    
while getopts "m:H:p:g:h" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        H) BACKEND_HOST="$OPTARG" ;;
        p) BACKEND_PORT="$OPTARG" ;;
        g) GHIDRA_PORT="$OPTARG" ;;
        h) echo "用法: $0 -m <gdb|ghidra> -H <backend_host> -p <backend_port> -g <ghidra_port>"; exit 0 ;;
        *) exit 1 ;;
    esac
done

# run the selected frontend
if [[ "$MODE" == "gdb" ]]
then
    ./src/gdb_connect.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf -p $BACKEND_PORT
elif [[ "$MODE" == "ghidra" ]]
then
    ./src/gdb_ghidra_connect.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf -H $BACKEND_HOST -p $BACKEND_PORT \
    -g /path/to/ghidra_12.0.4_PUBLIC -G auto:$GHIDRA_PORT -V .venv
else
    echo "invalid mode: $MODE, please choose gdb or ghidra"
    exit 1
fi