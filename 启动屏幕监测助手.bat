@echo off
REM 启动屏幕监测助手控制面板
start "" "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor-console.ps1"
