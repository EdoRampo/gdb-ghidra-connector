#!/usr/bin/env bash
# ============================================================
# gdb_ghidra_connect.sh —— 独立运行的 GDB / Ghidra 联调脚本
#
# 流程： gdb-multiarch 连接 backend_qemu.sh / backend_openocd.sh
#        暴露的端口 -> (可选) 同一个 gdb 会话再通过 Trace RMI
#        接入 Ghidra Debugger，使 Ghidra 实时同步/控制这个会话。
#
# 重要说明（容易搞混的一点）：
#   GDB 的 Remote Serial Protocol (RSP) 端口一次只能有一个客户端
#   控制目标。所以 Ghidra 并不是开第二个连接去抢 QEMU/OpenOCD 的
#   1234/3333 端口 —— 而是由本脚本里的 gdb-multiarch 独占那个连接，
#   再通过 Ghidra 官方提供的 python 插件 `ghidragdb`，把这一个 gdb
#   会话反向连接到 Ghidra 的 Trace RMI 服务上（Ghidra 那边是"接收方"）。
#   这样你在本终端敲 gdb 命令，Ghidra Debugger 窗口里的反汇编/内存/
#   寄存器视图会跟着实时同步。
#
# 准备工作（一次性）：
#   1) gdb 必须内嵌 Python3（`gdb -q -ex "python import sys; print(sys.version)"` 能跑通）
#   2) 需要 ghidragdb / ghidratrace 这两个 python 包能被 gdb 的 python import
#      到 —— 要么 pip 装好，要么用 -g 指定 GHIDRA_HOME 让本脚本自动拼 PYTHONPATH
#      （对应 Ghidra 安装目录下 Ghidra/Debug/Debugger-agent-gdb/pypkg/src 和
#       Ghidra/Debug/Debugger-rmi-trace/pypkg/src）
#   3) 在 Ghidra 打开 Debugger 工具 -> Connections 窗口，推荐点
#      "Start a persistent server, able to accept many back-end connections"
#      而不是 "Accept a single inbound TCP connection"：后者是一次性的，
#      只要有任何 TCP 连接（哪怕是纯粹的连通性测试、没发任何协议数据）碰它
#      一下就会被消耗掉，之后 gdb 真正连接时反而会因为监听器已经关闭而报
#      "Could not receive negotiation request" 之类的错误。持久模式没有
#      这个坑，端口会一直开着，随便重跑本脚本都不用回 Ghidra 里重新点。
#      记下 Ghidra 显示的 host:port，就是本脚本 -G 参数要填的地址
#
# 用法：
#   # 只连 target，不接 Ghidra（纯命令行调试）
#   ./gdb_ghidra_connect.sh -a arm -p 1234
#
#   # 连 target，同时接入 Ghidra Trace RMI（用 venv 提供 psutil/protobuf）
#   ./gdb_ghidra_connect.sh -a arm -p 1234 -f ./firmware.elf \
#       -g /opt/ghidra_11.3 -G 127.0.0.1:18932 -V ~/.venvs/ghidra-gdb
#
#   # 连 OpenOCD (extended-remote 更适合真实硬件场景)
#   ./gdb_ghidra_connect.sh -a arm -p 3333 -T extended-remote \
#       -f ./firmware.elf -g /opt/ghidra_11.3 -G 127.0.0.1:18932
# ============================================================
set -euo pipefail

ARCH="arm"                  # arm | mips
TARGET_HOST="127.0.0.1"
TARGET_PORT=1234
TARGET_TYPE="remote"        # remote | extended-remote
FIRMWARE=""                 # 符号文件 (elf)，用于 file 命令 + 断点符号解析
GDB_BIN="gdb-multiarch"
BREAK_AT=""                 # 例如 *0x08000000，留空则不自动下断点
GHIDRA_HOME=""               # -g，用于拼接 PYTHONPATH（未 pip 安装 ghidragdb 时需要）
GHIDRA_TRACE_ADDR=""         # -G host:port，Ghidra Connections 窗口给出的 Trace RMI 地址
FORCE_GHIDRA=0               # -F：即使依赖预检失败，也仍然把 ghidra 段写进 gdbinit
VENV_PATH=""                 # -V：venv 目录，把其 site-packages 拼进 PYTHONPATH（装 psutil/protobuf 用）
DIAGNOSE_NET=0                # -D：只做一次性网络探测并退出，注意会消耗 Ghidra 一次性 Accept 名额
LOG_DIR="./log/fw_debug_logs"
TS="$(date +%Y%m%d_%H%M%S)"

color_i="\033[1;34m"; color_ok="\033[1;32m"; color_w="\033[1;33m"; color_e="\033[1;31m"; rst="\033[0m"
log()  { echo -e "${color_i}[gdb] $(date '+%H:%M:%S')${rst} $*"; }
ok()   { echo -e "${color_ok}[gdb] $(date '+%H:%M:%S')${rst} $*"; }
warn() { echo -e "${color_w}[gdb] $(date '+%H:%M:%S')${rst} $*"; }
err()  { echo -e "${color_e}[gdb] $(date '+%H:%M:%S')${rst} $*" >&2; }

while getopts "a:H:p:T:f:b:g:G:L:V:FDh" opt; do
    case "$opt" in
        a) ARCH="$OPTARG" ;;
        H) TARGET_HOST="$OPTARG" ;;
        p) TARGET_PORT="$OPTARG" ;;
        T) TARGET_TYPE="$OPTARG" ;;
        f) FIRMWARE="$OPTARG" ;;
        b) BREAK_AT="$OPTARG" ;;
        g) GHIDRA_HOME="$OPTARG" ;;
        G) GHIDRA_TRACE_ADDR="$OPTARG" ;;
        L) LOG_DIR="$OPTARG" ;;
        V) VENV_PATH="$OPTARG" ;;
        F) FORCE_GHIDRA=1 ;;
        D) DIAGNOSE_NET=1 ;;
        h)
            echo "用法: $0 -a arm|mips -p 端口 [-H host] [-T remote|extended-remote]"
            echo "        [-f 固件elf] [-b 断点地址] [-g GHIDRA_HOME] [-G ghidra_host:port]"
            echo "        [-V venv目录] [-F 跳过依赖预检强行写入]"
            echo "        [-D 仅网络诊断并退出，会消耗Ghidra一次性Accept名额] [-L 日志目录]"
            exit 0 ;;
        *) exit 1 ;;
    esac
done

command -v "$GDB_BIN" >/dev/null 2>&1 || { err "找不到 $GDB_BIN，请安装 gdb-multiarch"; exit 1; }

# ---- -G auto:端口 —— 自动探测 WSL2 默认网关（Windows 宿主机地址）----
# Win10 没有镜像网络模式，Ghidra 跑在 Windows、gdb 跑在 WSL2 时，
# 每次 wsl --shutdown/重启网关 IP 可能会变，这里省得手动查再拷贝。
if [[ "$GHIDRA_TRACE_ADDR" == auto:* ]]; then
    AUTO_PORT="${GHIDRA_TRACE_ADDR#auto:}"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        AUTO_HOST="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
        if [[ -z "$AUTO_HOST" ]]; then
            err "auto: 探测默认网关失败（ip route show default 没有输出），请手动查询后用 -G <ip>:${AUTO_PORT}"
            exit 1
        fi
        GHIDRA_TRACE_ADDR="${AUTO_HOST}:${AUTO_PORT}"
        log "auto: 已探测到 WSL2 默认网关 -> 使用 -G ${GHIDRA_TRACE_ADDR}"
    else
        err "auto: 只在 WSL2 环境里有意义（用来找 Windows 宿主机地址），当前不是 WSL2，请直接用 -G <ip>:${AUTO_PORT}"
        exit 1
    fi
fi

mkdir -p "$LOG_DIR"
GDB_LOG="$LOG_DIR/gdb_session_${TS}.log"
GDBINIT_FILE="$LOG_DIR/.gdbinit_${TS}"

case "$ARCH" in
    arm)  GDB_ARCH="arm" ;;
    mips) GDB_ARCH="mips" ;;
    *) err "未知架构: $ARCH（支持 arm/mips）"; exit 1 ;;
esac

log "目标: ${TARGET_TYPE} ${TARGET_HOST}:${TARGET_PORT}  架构=${GDB_ARCH}"

# ---- 检查 gdb 是否内嵌 python3，ghidragdb 桥接依赖这个 ----
GDB_PY_VERSION=""
if [[ -n "$GHIDRA_TRACE_ADDR" || -n "$VENV_PATH" ]]; then
    if ! "$GDB_BIN" -q -batch -ex "python import sys; print(sys.version.split()[0])" >/tmp/.gdbpycheck 2>&1; then
        warn "gdb 似乎没有内嵌可用的 Python3，ghidragdb 桥接可能会失败"
        warn "$(cat /tmp/.gdbpycheck)"
    else
        GDB_PY_VERSION="$(tail -n1 /tmp/.gdbpycheck)"
        ok "gdb 内嵌 Python: $GDB_PY_VERSION"
    fi
fi

# ---- 用 -V 指定的 venv 提供 psutil/protobuf 等依赖 ----
# gdb 内嵌解释器不会因为 shell 里 activate 了 venv 就自动认得它，
# 必须显式把 venv 的 site-packages 塞进 PYTHONPATH；并且 venv 是共享
# 系统 Python 的 so/ABI 建出来的，版本必须和 gdb 内嵌的 Python 版本一致，
# 否则一样会 import 失败。
VENV_SITE_PACKAGES=""
if [[ -n "$VENV_PATH" ]]; then
    if [[ ! -x "$VENV_PATH/bin/python3" ]]; then
        err "在 $VENV_PATH/bin/python3 找不到可执行文件，-V 指向的不是一个有效 venv"
        exit 1
    fi
    VENV_PY_VERSION="$("$VENV_PATH/bin/python3" -c 'import platform;print(platform.python_version())')"
    VENV_SITE_PACKAGES="$("$VENV_PATH/bin/python3" -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])')"

    log "venv: $VENV_PATH  (Python $VENV_PY_VERSION)  site-packages=$VENV_SITE_PACKAGES"

    if [[ -n "$GDB_PY_VERSION" ]]; then
        GDB_PY_MAJMIN="${GDB_PY_VERSION%.*}"
        VENV_PY_MAJMIN="${VENV_PY_VERSION%.*}"
        if [[ "$GDB_PY_MAJMIN" != "$VENV_PY_MAJMIN" ]]; then
            err "版本不匹配：gdb 内嵌 Python $GDB_PY_VERSION，venv 是 Python $VENV_PY_VERSION"
            err "venv 必须用 python${GDB_PY_MAJMIN} 创建（例如: python${GDB_PY_MAJMIN} -m venv $VENV_PATH），否则 import 仍会失败"
            exit 1
        fi
        ok "venv Python 版本与 gdb 内嵌版本一致 ($GDB_PY_MAJMIN.x)"
    fi

    if [[ ! -d "$VENV_SITE_PACKAGES" ]]; then
        err "venv site-packages 目录不存在: $VENV_SITE_PACKAGES"
        exit 1
    fi
fi

# ---- 拼接 PYTHONPATH（若指定了 GHIDRA_HOME，且 ghidragdb 尚未 pip 安装）----
PYTHONPATH_EXPORT=""
AGENT_DIST=""   # Debugger-agent-gdb 的 wheel 目录（用于报错时给出精确 pip 命令）
RMI_DIST=""     # Debugger-rmi-trace 的 wheel 目录
if [[ -n "$GHIDRA_HOME" ]]; then
    if [[ -d "$GHIDRA_HOME/.git" ]]; then
        AGENT_SRC="$GHIDRA_HOME/Ghidra/Debug/Debugger-agent-gdb/build/pypkg/src"
        RMI_SRC="$GHIDRA_HOME/Ghidra/Debug/Debugger-rmi-trace/build/pypkg/src"
    else
        AGENT_SRC="$GHIDRA_HOME/Ghidra/Debug/Debugger-agent-gdb/pypkg/src"
        RMI_SRC="$GHIDRA_HOME/Ghidra/Debug/Debugger-rmi-trace/pypkg/src"
    fi
    AGENT_DIST="$GHIDRA_HOME/Ghidra/Debug/Debugger-agent-gdb/pypkg/dist"
    RMI_DIST="$GHIDRA_HOME/Ghidra/Debug/Debugger-rmi-trace/pypkg/dist"

    if [[ -d "$AGENT_SRC" && -d "$RMI_SRC" ]]; then
        PYTHONPATH_EXPORT="${RMI_SRC}:${AGENT_SRC}:${PYTHONPATH:-}"
        log "已从 GHIDRA_HOME 定位 ghidragdb/ghidratrace 源码路径，拼入 PYTHONPATH"
    else
        warn "在 GHIDRA_HOME 下未找到 pypkg/src: $AGENT_SRC / $RMI_SRC"
        warn "发行版(release)安装通常没有可直接 import 的源码目录，"
        warn "需要改用下面预检失败时给出的 pip install 方式（装 dist/ 下的 .whl）"
    fi
fi

if [[ -n "$PYTHONPATH_EXPORT" || -n "$VENV_SITE_PACKAGES" ]]; then
    export PYTHONPATH="${VENV_SITE_PACKAGES:+$VENV_SITE_PACKAGES:}${PYTHONPATH_EXPORT}"
    log "PYTHONPATH=$PYTHONPATH"
fi

# ---- 预检：psutil / ghidratrace / ghidragdb 能否被 gdb 内嵌的 python import ----
# 这一步专门用来复现并提前捕获你之前遇到的报错：
#   "Unable to import 'psutil'" / "Cannot find Python source for Debugger-rmi-trace"
# 只要有一个 import 失败，就不把 ghidra 相关命令写进 .gdbinit（否则 gdb 会在
# sourced 文件中途报错并中止，殃及后面本该正常执行的命令），除非用 -F 强制。
GHIDRA_PY_READY=0
if [[ -n "$GHIDRA_TRACE_ADDR" ]]; then
    log "预检 Ghidra Python 依赖 (psutil / ghidratrace / ghidragdb) ..."
    PREFLIGHT_LOG="$LOG_DIR/ghidra_py_preflight_${TS}.log"
    mkdir -p "$LOG_DIR"
    set +e
    "$GDB_BIN" -q -batch \
        -ex "python import psutil; print('PSUTIL_OK')" \
        -ex "python import ghidratrace; print('GHIDRATRACE_OK')" \
        -ex "python import ghidragdb; print('GHIDRAGDB_OK')" \
        > "$PREFLIGHT_LOG" 2>&1
    set -e

    if grep -q GHIDRAGDB_OK "$PREFLIGHT_LOG"; then
        GHIDRA_PY_READY=1
        ok "预检通过：psutil / ghidratrace / ghidragdb 均可正常 import"
    else
        err "Ghidra Python 依赖预检失败，详情见: $PREFLIGHT_LOG"
        echo "---- 预检输出 ----"
        cat "$PREFLIGHT_LOG"
        echo "-------------------"

        if ! grep -q PSUTIL_OK "$PREFLIGHT_LOG"; then
            warn "缺少 psutil，用 gdb 内嵌 python 对应的包管理器装（通常是系统 python3）："
            echo "    # 方式一：venv + -V 参数（推荐，不污染系统环境）"
            echo "    python3 -m venv /path/to/venv && /path/to/venv/bin/pip install psutil protobuf"
            echo "    # 然后重跑本脚本时加上: -V /path/to/venv"
            echo "    # 方式二：走系统包管理，最贴合 gdb 内嵌解释器"
            echo "    sudo apt update && sudo apt install -y python3-psutil python3-protobuf"
            echo "    # 方式三：较新的 Ubuntu/Debian 默认启用 PEP668 保护，直接 pip install 会被拒绝，"
            echo "    #        需要显式加 --break-system-packages（会装进系统环境，不如方式一干净）"
            echo "    pip3 install --break-system-packages psutil protobuf"
        fi
        if ! grep -q GHIDRATRACE_OK "$PREFLIGHT_LOG"; then
            warn "ghidratrace / ghidragdb 未能被 import。发行版 Ghidra 通常不能只靠 PYTHONPATH"
            warn "指向源码目录，需要用 pip 直接安装官方预编译的 wheel："
            if [[ -n "$RMI_DIST" && -n "$AGENT_DIST" ]]; then
                echo "    pip3 install --no-index -f \"$RMI_DIST\" -f \"$AGENT_DIST\" ghidratrace ghidragdb"
            else
                echo "    # 先用 -g 指定 GHIDRA_HOME 让脚本定位 wheel 目录，或手动执行："
                echo "    pip3 install --no-index \\"
                echo "        -f <GHIDRA_HOME>/Ghidra/Debug/Debugger-rmi-trace/pypkg/dist \\"
                echo "        -f <GHIDRA_HOME>/Ghidra/Debug/Debugger-agent-gdb/pypkg/dist \\"
                echo "        ghidratrace ghidragdb"
            fi
            warn "若 dist/ 目录下没有 .whl 文件（部分安装包需要自己 build）："
            echo "    cd <GHIDRA_HOME>/Ghidra/Debug/Debugger-rmi-trace/pypkg && python3 -m build"
            echo "    cd <GHIDRA_HOME>/Ghidra/Debug/Debugger-agent-gdb/pypkg   && python3 -m build"
            echo "    # 然后再执行上面的 pip3 install --no-index -f ... 命令"
        fi
        warn "装完依赖后重新运行本脚本即可；也可以加 -F 先跳过预检强行连（大概率会在 gdbinit 里报同样的错）"

        if [[ "$FORCE_GHIDRA" -eq 1 ]]; then
            warn "-F 已指定：仍会把 Ghidra 接入段写进 .gdbinit（预期会复现上面的错误）"
            GHIDRA_PY_READY=1
        else
            warn "本次将跳过 Ghidra 接入段，仅做纯 gdb 调试（target remote 部分不受影响）"
            GHIDRA_TRACE_ADDR=""
        fi
    fi
fi

# ---- 网络可达性诊断（默认关闭）----
# 重要教训：Ghidra 的 "Accept a single inbound TCP connection" 是一次性的——
# 它会把它的名额发给"下一个连上来的 TCP 连接"，不管这个连接有没有发送真正的
# Trace RMI 协议数据。之前这里默认会用一次裸 TCP 连接去"探路"，结果恰恰是
# 这个探测本身抢走了 Ghidra 的一次性名额，导致真正的 gdb 连接反而拿不到，
# Ghidra 端报 "Could not receive negotiation request"。所以现在默认不再自动
# 探测，只有显式加 -D 时才做这个诊断（用于确实怀疑是网络/防火墙问题、且你
# 这次不在乎会消耗掉 Ghidra 一次性名额、之后会重新点一次 Accept 的场合）。
if [[ -n "$GHIDRA_TRACE_ADDR" && "$DIAGNOSE_NET" -eq 1 ]]; then
    GT_HOST="${GHIDRA_TRACE_ADDR%%:*}"
    GT_PORT="${GHIDRA_TRACE_ADDR##*:}"
    warn "-D 已指定：即将用一次裸 TCP 连接探测 ${GT_HOST}:${GT_PORT}"
    warn "如果 Ghidra 用的是一次性 \"Accept a single inbound TCP connection\"，"
    warn "这次探测会消耗掉那个名额 —— 探测完之后需要回 Ghidra 重新点一次 Accept，"
    warn "再重跑本脚本（不带 -D）才能真正连上"
    NET_T0=$(date +%s)
    set +e
    timeout 4 bash -c "exec 3<>\"/dev/tcp/${GT_HOST}/${GT_PORT}\"" 2>/dev/null
    NET_RC=$?
    set -e
    NET_ELAPSED=$(( $(date +%s) - NET_T0 ))

    if [[ "$NET_RC" -eq 0 ]]; then
        ok "探测通过：${GT_HOST}:${GT_PORT} 网络路径可达（TCP 层面）"
    elif [[ "$NET_ELAPSED" -ge 4 ]]; then
        err "连接 ${GT_HOST}:${GT_PORT} 超时（${NET_ELAPSED}s 无任何响应，非即时拒绝）"
        warn "这个耗时特征通常指向【防火墙静默丢包】：真拒绝一般是毫秒级返回，"
        warn "卡到超时更像是 SYN 包被丢弃。可在 Windows PowerShell（管理员）执行："
        echo "    Get-NetConnectionProfile   # 找到 vEthernet (WSL) 的 NetworkCategory"
        echo "    New-NetFirewallRule -DisplayName \"WSL Ghidra TraceRMI ${GT_PORT}\" \\"
        echo "        -Direction Inbound -Protocol TCP -LocalPort ${GT_PORT} -Action Allow -Profile Any"
    else
        err "连接 ${GT_HOST}:${GT_PORT} 被立即拒绝（${NET_ELAPSED}s，网络路径本身是通的）"
        warn "只是这个端口上此刻没人监听：去 Ghidra 点一下 Accept，或确认端口/地址填对了"
    fi
    exit 0
fi

if [[ -n "$GHIDRA_TRACE_ADDR" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    warn "提示：确保已经在 Ghidra 点了 \"Accept a single inbound TCP connection\""
    warn "（一次性，必须在接下来 gdb 真正发起 ghidra trace connect 之前点，"
    warn "点太早可能已经过期；如果反复失败，改用 Ghidra 的持久 Trace RMI Server"
    warn "模式代替一次性 Accept，就不用每次都掐时间点按钮了）"
fi

# ---- 生成 .gdbinit ----
# 已知坑点：set architecture 必须写在 target remote 之后执行，
# 否则会被 target remote 触发的自动架构探测覆盖。
{
    echo "# 自动生成 $(date)"
    echo "set pagination off"
    echo "set confirm off"
    echo "set logging file ${GDB_LOG}"
    echo "set logging enabled on"
    echo ""
    if [[ -n "$FIRMWARE" ]]; then
        echo "file ${FIRMWARE}"
    fi
    echo "target ${TARGET_TYPE} ${TARGET_HOST}:${TARGET_PORT}"
    echo "set architecture ${GDB_ARCH}"
    echo "echo \\n[gdbinit] 已连接 ${TARGET_TYPE} ${TARGET_HOST}:${TARGET_PORT}, 架构=${GDB_ARCH}\\n"
    echo ""
    if [[ -n "$BREAK_AT" ]]; then
        echo "break ${BREAK_AT}"
        echo "echo [gdbinit] 已在 ${BREAK_AT} 设置断点\\n"
    fi
    echo ""
    if [[ -n "$GHIDRA_TRACE_ADDR" ]]; then
        echo "# ---- 接入 Ghidra Debugger (Trace RMI) ----"
        echo "python import ghidragdb"
        echo "echo [gdbinit] 已加载 ghidragdb 插件\\n"
        echo "ghidra trace connect \"${GHIDRA_TRACE_ADDR}\""
        echo "echo [gdbinit] 已连接 Ghidra Trace RMI: ${GHIDRA_TRACE_ADDR}\\n"
        echo "ghidra trace start"
        echo "ghidra trace sync-enable"
        echo "ghidra trace sync-synth-stopped"
        echo "echo [gdbinit] Ghidra 同步已启用：Ghidra Debugger 窗口将随本次 gdb 会话实时刷新\\n"
    else
        echo "echo [gdbinit] 未指定 -G，跳过 Ghidra Trace RMI 接入（纯命令行调试模式）\\n"
    fi
    echo "set confirm on"
} > "$GDBINIT_FILE"

ok "已生成 GDB init 脚本: $GDBINIT_FILE"
[[ -n "$GHIDRA_TRACE_ADDR" ]] && ok "将尝试接入 Ghidra Trace RMI: $GHIDRA_TRACE_ADDR"

if [[ -z "$GHIDRA_TRACE_ADDR" ]]; then
    cat <<EOF

------------------------------------------------------------
提示：当前未连接 Ghidra Debugger。若要接入：
  1) 在 Ghidra 打开 Debugger 工具 -> Connections 窗口 ->
     点击 "Accept a single inbound TCP connection"（或保持
     Trace RMI Server 常驻监听）
  2) 记下弹出/显示的 host:port
  3) 重新运行本脚本并加上: -G <host:port> -g <GHIDRA_HOME路径>
------------------------------------------------------------
EOF
fi

log "启动 ${GDB_BIN}，会话日志 -> ${GDB_LOG}"
echo "------------------------------------------------------------"

exec "$GDB_BIN" -q -x "$GDBINIT_FILE"