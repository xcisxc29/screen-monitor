@echo off
REM 停止 服务+热键+悬浮窗
setlocal
set "BASE=%~dp0"
if exist "%BASE%service.pid" (
  set /p SVPID=<"%BASE%service.pid"
  taskkill /PID %SVPID% /F >nul 2>&1
  if errorlevel 1 ( echo Service not running. ) else ( echo Service stopped (PID %SVPID%). )
)
if exist "%BASE%hotkey.pid" (
  set /p HKPID=<"%BASE%hotkey.pid"
  taskkill /PID %HKPID% /F >nul 2>&1
  if errorlevel 1 ( echo Hotkey not running. ) else ( echo Hotkey stopped (PID %HKPID%). )
)
if exist "%BASE%overlay.pid" (
  set /p OVPID=<"%BASE%overlay.pid"
  taskkill /PID %OVPID% /F >nul 2>&1
  if errorlevel 1 ( echo Overlay not running. ) else ( echo Overlay closed (PID %OVPID%). )
)
echo Done.
