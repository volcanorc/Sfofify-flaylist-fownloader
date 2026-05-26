@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-web.ps1" %*
echo.
echo [start-web] Server stopped or exited.
echo Press Enter to close this window.
pause >nul
