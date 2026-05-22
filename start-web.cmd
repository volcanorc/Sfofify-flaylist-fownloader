@echo off
setlocal
call "%~dp0repair.cmd"
if errorlevel 1 exit /b %errorlevel%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-web.ps1" -SkipRepair %*
