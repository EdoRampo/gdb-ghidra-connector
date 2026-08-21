# gdb-ghidra-connector
Dynamically debug firmware via GDB connection to GHIDRA

> 依赖：qemu-system/openocd/gdb-multiarch/ghidra>12.0

## Ghidra Environments
安装 Ghidra-Debugger 的依赖
```bash
# using virtual environments
python -m venv .venv
source .venv/bin/activate

# requirements
pip3 install psutil protobuf

# ghidra-debugger
pip3 install --no-index \
    -f <GHIDRA_HOME>/Ghidra/Debug/Debugger-rmi-trace/pypkg/dist \
    -f <GHIDRA_HOME>/Ghidra/Debug/Debugger-agent-gdb/pypkg/dist \
    ghidratrace ghidragdb
```
Ghidra Debugger 的配置  
在 Ghidra 打开 Debugger 工具 -> Connections 窗口 -> 点击 "Accept a single inbound TCP connection"（或保持 Trace RMI Server 常驻监听
> Note: win11-wsl2-mirror 模式下监听网络配置 --> 127.0.0.1:port
> win10-wsl 模式下监听网络配置 --> 0.0.0.0:port