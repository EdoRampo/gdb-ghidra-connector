#!/usr/bin/env bash
# ============================================================
# backend_qemu.sh —— 独立运行的 QEMU 后端脚本
#
# 职责单一：只负责把 QEMU（P2IM patched build）跑起来，暴露 GDB stub
# 端口，供其它终端里的 gdb_ghidra_connect.sh 连接。不启动 GDB，不管 Ghidra。
#
# 建议：在单独的终端/tmux pane 里前台运行，保持可见的串口/monitor 回显。
#
# 用法：
#   ./backend_qemu.sh -a arm -f ./firmware.elf \
#       -Q "-machine configurable -cpu cortex-m3 -nographic"
#   ./backend_qemu.sh -a mips -f ./firmware.bin -Q "-machine mipssim -nographic"
# ============================================================
set -euo pipefail

ARCH="arm"                # arm | mips
FIRMWARE=""
GDB_PORT=1234
MONITOR_PORT=4444
EXTRA_ARGS="-machine configurable -nographic"
LOG_DIR="./fw_debug_logs"
START_HALTED=1            # 1: 加 -S，等待 gdb attach 后再跑；0: 直接跑

color_i="\033[1;34m"; color_ok="\033[1;32m"; color_e="\033[1;31m"; rst="\033[0m"
log()  { echo -e "${color_i}[qemu] $(date '+%H:%M:%S')${rst} $*"; }
ok()   { echo -e "${color_ok}[qemu] $(date '+%H:%M:%S')${rst} $*"; }
err()  { echo -e "${color_e}[qemu] $(date '+%H:%M:%S')${rst} $*" >&2; }

while getopts "a:f:p:M:m:Q:L:Sh" opt; do
    case "$opt" in
        a) ARCH="$OPTARG" ;;
        f) FIRMWARE="$OPTARG" ;;
        p) GDB_PORT="$OPTARG" ;;
        M) MONITOR_PORT="$OPTARG" ;;
        Q) EXTRA_ARGS="$OPTARG" ;;
        L) LOG_DIR="$OPTARG" ;;
        S) START_HALTED=0 ;;   # -S 表示"关闭"启动即挂起（选项名沿用直觉：加 -S 就是不挂起）
        h) echo "用法: $0 -a arm|mips -f firmware [-p gdb端口] [-M monitor端口] [-Q \"额外qemu参数\"] [-L 日志目录] [-S 不预先挂起]"; exit 0 ;;
        *) exit 1 ;;
    esac
done

case "$ARCH" in
    arm)  QBIN="qemu-system-arm" ;;
    mips) QBIN="qemu-system-mipsel" ;;
    *) err "未知架构: $ARCH（支持 arm/mips）"; exit 1 ;;
esac

command -v "$QBIN" >/dev/null 2>&1 || { err "找不到 $QBIN，请确认已安装 P2IM patched QEMU 并在 PATH 中"; exit 1; }
[[ -n "$FIRMWARE" ]] || { err "需要 -f 指定固件路径 (elf/bin)"; exit 1; }
[[ -f "$FIRMWARE" ]] || { err "固件文件不存在: $FIRMWARE"; exit 1; }

mkdir -p "$LOG_DIR"
BACKEND_LOG="$LOG_DIR/qemu_$(date +%Y%m%d_%H%M%S).log"

HALT_FLAG=""
[[ "$START_HALTED" -eq 1 ]] && HALT_FLAG="-S"

log "架构=$ARCH  固件=$FIRMWARE  GDB端口=$GDB_PORT  Monitor端口=$MONITOR_PORT"
log "命令: $QBIN $EXTRA_ARGS -kernel $FIRMWARE -monitor telnet:127.0.0.1:${MONITOR_PORT},server,nowait -gdb tcp::${GDB_PORT} ${HALT_FLAG}"
[[ "$START_HALTED" -eq 1 ]] && log "已加 -S：CPU 将挂起，等待 gdb_ghidra_connect.sh 连接后再执行"
ok "串口/系统输出将实时回显在本终端，同时写入: $BACKEND_LOG"
ok "Monitor 可用: telnet 127.0.0.1 ${MONITOR_PORT}"
echo "------------------------------------------------------------"

# tee 让本终端能实时看到回显，同时落盘日志
# shellcheck disable=SC2086
exec "$QBIN" $EXTRA_ARGS \
    -kernel "$FIRMWARE" \
    -monitor "telnet:127.0.0.1:${MONITOR_PORT},server,nowait" \
    -gdb "tcp::${GDB_PORT}" \
    $HALT_FLAG \
    2>&1 | tee "$BACKEND_LOG"