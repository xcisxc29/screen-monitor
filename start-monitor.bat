@echo off
REM 启动监测服务 + 全局热键
start "" "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0monitor-service.ps1"
start "" "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0hotkey.ps1"
echo Monitor service started. Ctrl+Shift+S = analyze now.
