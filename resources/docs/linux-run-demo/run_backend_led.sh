#!/usr/bin/env bash

# default config
MODE=qemu
OPENOCD_PATH=</path/to/xpack-openocd-xx.xx.xx-x/openocd/scripts>

# parse command line arguments
while getopts "b:p:h" opt; do
  case $opt in
    b) MODE="$OPTARG" ;;
    p) OPENOCD_PATH="$OPTARG" ;;
    h) echo "[usage] $0 -b <qemu|openocd(default)> -p <openocd-scripts-path(default: $OPENOCD_PATH)>"; exit 0 ;;
    \?) echo "invalid option: -$OPTARG" ;;
    *) exit 1 ;;
  esac
done

# run the selected backend
if [[ "$MODE" == "qemu" ]]
then
    ./src/backend_qemu.sh -a arm -f ./resources/samples/others/nucleo_fre411_gpio_led.axf \
        -L ./log/fw_debug_logs \
        -p 1234 -M 1235 \
        -Q "-machine netduinoplus2 -nographic -serial null -serial mon:stdio -S -d guest_errors,unimp,in_asm -D ./log/qemu_stm32f411.log"

elif [[ "$MODE" == "openocd" ]]
then
    ./src/backend_openocd.sh \
        -c "$OPENOCD_PATH/interface/stlink.cfg" \
        -c "$OPENOCD_PATH/target/stm32f4x.cfg" \
        -L ./log/fw_debug_logs \
        -p 3333

else
    echo "invalid mode: $MODE, please choose qemu or openocd";
    exit 1
fi