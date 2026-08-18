@echo off
REM 启动悬浮窗
start "" "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0overlay-window.ps1"
echo Floating window started. Esc to close.
