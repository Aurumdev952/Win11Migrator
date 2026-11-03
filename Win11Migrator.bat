@echo off
:: Win11Migrator - Double-click launcher
:: Asks for administrator rights, then starts the PowerShell GUI from this folder.
:: Installing is the MSI's job; this file only launches.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

:: The execution policy is relaxed for this one process only; system policy is left untouched.
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Win11Migrator.ps1" %*
set "EXITCODE=%errorlevel%"
popd
exit /b %EXITCODE%
