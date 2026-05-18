@echo off
REM ============================================================
REM build-dist.bat - wrapper for build-dist.ps1
REM ============================================================
REM Runs the PowerShell script via double-click, bypassing the
REM execution policy (-ExecutionPolicy Bypass).
REM
REM Usage:
REM   build-dist.bat                  clean copy
REM   build-dist.bat -Compile         also compiles to .exe
REM   build-dist.bat -Compile -Zip    also zips
REM   build-dist.bat -Force           overwrites dest without prompt

setlocal

set "PS_SCRIPT=%~dp0build-dist.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: build-dist.ps1 not found in %~dp0
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*

echo.
pause
endlocal
