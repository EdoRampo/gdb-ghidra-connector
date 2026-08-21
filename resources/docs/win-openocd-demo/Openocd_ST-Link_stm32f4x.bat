@echo off
setlocal

:: OpenOCD 配置文件路径
set "config_path=D:\PROGRAM\Hardware\xpack-openocd-0.12.0-7\openocd\scripts"

:: 启动 OpenOCD
openocd -f "%config_path%\interface\stlink.cfg" -f "%config_path%\target\stm32f4x.cfg"

endlocal
pause