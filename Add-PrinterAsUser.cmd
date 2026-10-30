@echo off
REM ---------------------------------------------------------------------------
REM  Launcher for Add-PrinterAsUser.ps1
REM
REM  The PowerShell execution policy is checked BEFORE the script file is read,
REM  so a script cannot lift its own restriction. The bypass has to come from
REM  whatever launches it - which is this file. Run this instead of the .ps1 and
REM  no Set-ExecutionPolicy step is ever needed.
REM
REM  Exit code is passed straight through (0 = verified, 1 = failed).
REM ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0Add-PrinterAsUser.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: not found: "%SCRIPT%"
    if "%~1"=="" pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Exit code %RC%.
    if "%~1"=="" pause
)

exit /b %RC%
