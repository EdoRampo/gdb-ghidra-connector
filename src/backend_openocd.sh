#!/usr/bin/env bash
# ============================================================
# backend_openocd.sh —— 独立运行的 OpenOCD 后端脚本
#
# 职责单一：只负责把 OpenOCD 跑起来（真实硬件 / JTAG-SWD），暴露 GDB
# server 端口，供其它终端里的 gdb_ghidra_connect.sh 连接。
#
# 建议：在单独的终端/tmux pane 里前台运行，保持可见的 JTAG/SWD 回显。
#
# 用法：
#   ./backend_openocd.sh -c board/stm32f4discovery.cfg
#   ./backend_openocd.sh -c interface/stlink.cfg -c target/stm32f4x.cfg -p 3333
#   (多个 -c 会按顺序传给 openocd -f)
# ============================================================
set -euo pipefail

declare -a CFG_FILES=()
GDB_PORT=3333
TELNET_PORT=4444
LOG_DIR="./log/fw_debug_logs"
OPENOCD_BIN="openocd"

color_i="\033[1;34m"; color_ok="\033[1;32m"; color_e="\033[1;31m"; rst="\033[0m"
log()  { echo -e "${color_i}[openocd] $(date '+%H:%M:%S')${rst} $*"; }
ok()   { echo -e "${color_ok}[openocd] $(date '+%H:%M:%S')${rst} $*"; }
err()  { echo -e "${color_e}[openocd] $(date '+%H:%M:%S')${rst} $*" >&2; }

while getopts "c:p:t:L:h" opt; do
    case "$opt" in
        c) CFG_FILES+=("$OPTARG") ;;
        p) GDB_PORT="$OPTARG" ;;
        t) TELNET_PORT="$OPTARG" ;;
        L) LOG_DIR="$OPTARG" ;;
        h) echo "用法: $0 -c cfg文件 [-c 更多cfg...] [-p gdb端口] [-t telnet端口] [-L 日志目录]"; exit 0 ;;
        *) exit 1 ;;
    esac
done

command -v "$OPENOCD_BIN" >/dev/null 2>&1 || { err "找不到 $OPENOCD_BIN，请确认已安装"; exit 1; }
[[ ${#CFG_FILES[@]} -gt 0 ]] || { err "至少需要一个 -c 配置文件，如 board/stm32f4discovery.cfg"; exit 1; }

mkdir -p "$LOG_DIR"
BACKEND_LOG="$LOG_DIR/openocd_$(date +%Y%m%d_%H%M%S).log"

CFG_ARGS=()
for f in "${CFG_FILES[@]}"; do CFG_ARGS+=("-f" "$f"); done

log "配置文件: ${CFG_FILES[*]}"
log "GDB端口=$GDB_PORT  Telnet端口=$TELNET_PORT"
ok "JTAG/SWD 输出将实时回显在本终端，同时写入: $BACKEND_LOG"
echo "------------------------------------------------------------"

exec "$OPENOCD_BIN" "${CFG_ARGS[@]}" \
    -c "gdb_port ${GDB_PORT}" \
    -c "telnet_port ${TELNET_PORT}" \
    2>&1 | tee "$BACKEND_LOG"