@echo off
setlocal
cd /d "%~dp0"
title Portfolio One Click Manager

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Portfolio.ps1"

set "RESULT=%ERRORLEVEL%"

echo.
if not "%RESULT%"=="0" (
    echo UPDATE FAILED.
) else (
    echo ASSET PROCESSING COMPLETE.
)
pause
exit /b %RESULT%