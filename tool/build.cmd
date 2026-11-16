@echo off
setlocal
title Take A Look V2 - Desktop Build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set "build_exit_code=%errorlevel%"
echo.
if not "%build_exit_code%"=="0" echo Build failed with exit code %build_exit_code%.
if not defined TAL_NO_PAUSE pause
exit /b %build_exit_code%
