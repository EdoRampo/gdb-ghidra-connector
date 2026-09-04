#!/usr/bin/env bash
# ============================================================
# gdb_connect.sh —— 仅连接 QEMU/OpenOCD 的 GDB 前端
#
# 这个脚本与 gdb_ghidra_connect.sh 的区别是：不加载 ghidragdb，适合
# 先验证后端、断点和复位是否正常，再接入 Ghidra。
#
# 用法示例：
#   ./gdb_connect.sh -a arm -f ./firmware.elf -p 1234
#   ./gdb_connect.sh -a arm -f ./firmware.elf -p 3333 \
#       -T extended-remote -k hardware -R "monitor reset halt" -r
#
# 连接后可在 GDB 中执行：
#   target-reset       # 通过 monitor 复位后端
#   info breakpoints
#   continue
# ============================================================
set -euo pipefail

ARCH="arm"                  # arm | mips
TARGET_HOST="127.0.0.1"
TARGET_PORT=1234
TARGET_TYPE="remote"        # remote | extended-remote
FIRMWARE=""                 # ELF/AXF 等带符号文件
BREAK_AT=""                 # 例如 *0x08000000 或 main
BREAKPOINT_KIND="auto"      # auto | software | hardware
RESET_COMMAND=""             # -R，例如 "monitor reset halt"
RESET_ON_START=0             # -r：连接后立即复位一次
GDB_BIN="${GDB_BIN:-gdb-multiarch}"
LOG_DIR="./log/fw_debug_logs"
TS="$(date +%Y%m%d_%H%M%S)"

color_i="\033[1;34m"; color_ok="\033[1;32m"; color_w="\033[1;33m"; color_e="\033[1;31m"; rst="\033[0m"
log()  { echo -e "${color_i}[gdb] $(date '+%H:%M:%S')${rst} $*"; }
ok()   { echo -e "${color_ok}[gdb] $(date '+%H:%M:%S')${rst} $*"; }
warn() { echo -e "${color_w}[gdb] $(date '+%H:%M:%S')${rst} $*"; }
err()  { echo -e "${color_e}[gdb] $(date '+%H:%M:%S')${rst} $*" >&2; }

while getopts "a:H:p:T:f:b:k:R:rhL:" opt; do
    case "$opt" in
        a) ARCH="$OPTARG" ;;
        H) TARGET_HOST="$OPTARG" ;;
        p) TARGET_PORT="$OPTARG" ;;
        T) TARGET_TYPE="$OPTARG" ;;
        f) FIRMWARE="$OPTARG" ;;
        b) BREAK_AT="$OPTARG" ;;
        k) BREAKPOINT_KIND="$OPTARG" ;;
        R) RESET_COMMAND="$OPTARG" ;;
        r) RESET_ON_START=1 ;;
        L) LOG_DIR="$OPTARG" ;;
        h)
            echo "用法: $0 -a arm|mips -p 端口 [-H host] [-T remote|extended-remote]"
            echo "        [-f 固件elf] [-b 断点地址/符号] [-k auto|software|hardware]"
            echo "        [-R \"monitor reset halt\"] [-r 连接后立即复位] [-L 日志目录]"
            exit 0 ;;
        *) exit 1 ;;
    esac
done

command -v "$GDB_BIN" >/dev/null 2>&1 || {
    err "找不到 $GDB_BIN，请安装 gdb-multiarch，或通过 GDB_BIN 环境变量指定路径"
    exit 1
}

case "$ARCH" in
    arm)  GDB_ARCH="arm" ;;
    mips) GDB_ARCH="mips" ;;
    *) err "未知架构: $ARCH（支持 arm/mips）"; exit 1 ;;
esac

case "$TARGET_TYPE" in
    remote|extended-remote) ;;
    *) err "未知目标类型: $TARGET_TYPE（支持 remote/extended-remote）"; exit 1 ;;
esac

case "$BREAKPOINT_KIND" in
    auto|software|hardware) ;;
    *) err "未知断点类型: $BREAKPOINT_KIND（支持 auto/software/hardware）"; exit 1 ;;
esac

[[ -n "$FIRMWARE" ]] || warn "未指定 -f；只能使用裸地址断点，无法按函数名解析符号"
if [[ -n "$FIRMWARE" && ! -f "$FIRMWARE" ]]; then
    err "固件文件不存在: $FIRMWARE"
    exit 1
fi
FIRMWARE_IS_BIN=0
if [[ "${FIRMWARE,,}" == *.bin ]]; then
    FIRMWARE_IS_BIN=1
    warn ".bin 不包含 ELF 符号；请优先使用同一固件的 .elf/.axf，或用 -b *地址 设置断点"
fi

# 默认按项目后端端口猜测 reset 命令；也可用 -R 明确覆盖。
if [[ -z "$RESET_COMMAND" ]]; then
    case "$TARGET_PORT" in
        3333) RESET_COMMAND="monitor reset halt" ;;  # OpenOCD
        1234) RESET_COMMAND="monitor system_reset" ;; # QEMU
        *)     RESET_COMMAND="monitor reset halt" ;;
    esac
fi
if [[ "$RESET_COMMAND" == *$'\n'* || "$RESET_COMMAND" == *$'\r'* ]]; then
    err "-R 不能包含换行"
    exit 1
fi

mkdir -p "$LOG_DIR"
GDB_LOG="$LOG_DIR/gdb_session_${TS}.log"
GDBINIT_FILE="$LOG_DIR/.gdbinit_${TS}"

log "目标: ${TARGET_TYPE} ${TARGET_HOST}:${TARGET_PORT}  架构=${GDB_ARCH}"
log "复位命令: ${RESET_COMMAND}"

{
    echo "# 自动生成 $(date)"
    echo "set pagination off"
    echo "set confirm off"
    echo "set logging file \"${GDB_LOG//\"/\\\"}\""
    echo "set logging enabled on"
    echo ""
    if [[ -n "$FIRMWARE" && "$FIRMWARE_IS_BIN" -eq 0 ]]; then
        echo "file \"${FIRMWARE//\"/\\\"}\""
    fi
    echo "target ${TARGET_TYPE} ${TARGET_HOST}:${TARGET_PORT}"
    echo "set architecture ${GDB_ARCH}"
    # GDB 默认会根据 memory-map 自动选择软/硬件断点；显式打开该行为，
    # 让 OpenOCD/QEMU 提供只读 flash 映射时自动采用硬件断点。
    if [[ "$BREAKPOINT_KIND" == "auto" ]]; then
        echo "set breakpoint auto-hw on"
    fi
    echo "echo \\n[gdbinit] 已连接 ${TARGET_TYPE} ${TARGET_HOST}:${TARGET_PORT}, 架构=${GDB_ARCH}\\n"
    echo ""
    echo "define target-reset"
    echo "  ${RESET_COMMAND}"
    echo "end"
    echo "document target-reset"
    echo "  通过 monitor 命令复位后端目标。可用 -R 覆盖默认命令。"
    echo "end"
    echo "echo [gdbinit] 已定义 target-reset: ${RESET_COMMAND}\\n"
    if [[ "$RESET_ON_START" -eq 1 ]]; then
        echo "target-reset"
        echo "echo [gdbinit] 已执行启动复位\\n"
    fi
    if [[ -n "$BREAK_AT" ]]; then
        case "$BREAKPOINT_KIND" in
            hardware) BREAK_CMD="hbreak" ;;
            software|auto) BREAK_CMD="break" ;;
        esac
        echo "${BREAK_CMD} ${BREAK_AT}"
        echo "echo [gdbinit] 已用 ${BREAK_CMD} 在 ${BREAK_AT} 设置断点\\n"
    fi
    echo "set confirm on"
} > "$GDBINIT_FILE"

ok "已生成 GDB init 脚本: $GDBINIT_FILE"
log "启动 ${GDB_BIN}，会话日志 -> ${GDB_LOG}"
echo "------------------------------------------------------------"

exec "$GDB_BIN" -q -x "$GDBINIT_FILE"
