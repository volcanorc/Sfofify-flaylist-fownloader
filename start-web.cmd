@echo off
setlocal
call "%~dp0repair.cmd"
if errorlevel 1 exit /b %errorlevel%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-web.ps1" -SkipRepair %*
echo.
echo [start-web] Server stopped or exited.
echo Press Enter to close this window.
pause >nul
