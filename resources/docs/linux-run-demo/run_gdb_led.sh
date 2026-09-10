#!/usr/bin/env bash

# default config
MODE=gdb
GHIDRA_PATH=/path/to/ghidra_12.0.4_PUBLIC
BACKEND_HOST=localhost
BACKEND_PORT=1234
GHIDRA_HOST=auto
GHIDRA_PORT=18932    
RESET_HALT="monitor reset halt"  # default openocd reset halt command
while getopts "m:H:p:G:g:h:R" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        H) BACKEND_HOST="$OPTARG" ;;
        p) BACKEND_PORT="$OPTARG" ;;
        G) GHIDRA_HOST="$OPTARG" ;;
        g) GHIDRA_PORT="$OPTARG" ;;
        R) RESET_HALT="$OPTARG" ;;
        h) echo "用法: $0 -m <gdb|ghidra> -H <backend_host> -p <backend_port> -G <ghidra_host> -g <ghidra_port> -R <reset_halt_command>"; exit 0 ;;
        *) exit 1 ;;
    esac
done

# run the selected frontend
if [[ "$MODE" == "gdb" ]]
then
    ./src/gdb_connect.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf -p $BACKEND_PORT -r -R "$RESET_HALT"
elif [[ "$MODE" == "ghidra" ]]
then
    ./src/gdb_ghidra_connect.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf -r -R "$RESET_HALT" \
    -H $BACKEND_HOST -p $BACKEND_PORT \
    -g $GHIDRA_PATH -G $GHIDRA_HOST:$GHIDRA_PORT \
    -V .venv
else
    echo "invalid mode: $MODE, please choose gdb or ghidra"
    exit 1
fi/$GHIDRA_PATH