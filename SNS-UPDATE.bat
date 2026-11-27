@echo off
setlocal
cd /d "%~dp0"
title V30.18.2 - One Click SNS Updater

echo ============================================
echo DESIGNSKIN SNS PORTFOLIO UPDATER
echo ============================================
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-SNS.ps1"

set "RESULT=%ERRORLEVEL%"

echo.

if not "%RESULT%"=="0" (
    echo UPDATE FAILED. Check the error above.
) else (
    echo UPDATE COMPLETE.
    echo Review your website before GitHub Push.
)

echo.
pause
exit /b %RESULT%