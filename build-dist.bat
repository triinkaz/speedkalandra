@echo off
REM ============================================================
REM build-dist.bat - wrapper para build-dist.ps1
REM ============================================================
REM Permite rodar o script PowerShell via duplo-click contornando
REM execution policy (com -ExecutionPolicy Bypass).
REM
REM Uso:
REM   build-dist.bat                  copia limpa
REM   build-dist.bat -Compile         tambem compila .exe
REM   build-dist.bat -Compile -Zip    tambem zipa
REM   build-dist.bat -Force           sobrescreve dest sem perguntar

setlocal

set "PS_SCRIPT=%~dp0build-dist.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERRO: build-dist.ps1 nao encontrado em %~dp0
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*

echo.
pause
endlocal
