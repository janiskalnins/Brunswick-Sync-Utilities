@echo off
:: ============================================================
::  RunReset.cmd  --  Launcher for DisplayController-Reset.ps1
::  Compatible: Windows 10 / 11
:: ============================================================
setlocal EnableDelayedExpansion

:: ---- Resolve the directory this .cmd lives in (network-safe) ----
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%DisplayController-Reset.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Cannot find DisplayController-Reset.ps1 in:
    echo         %SCRIPT_DIR%
    echo.
    echo Make sure both files are in the same folder.
    pause
    exit /b 1
)

:: ---- Check for Administrator rights --------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator elevation...
    :: Re-launch self elevated, passing along original directory
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: ---- Unblock the PS1 so SmartScreen / Unknown Publisher won't fire -
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Unblock-File -Path '%PS_SCRIPT%' -ErrorAction SilentlyContinue"

:: ---- Launch the PowerShell script ----------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
    -File "%PS_SCRIPT%"

echo.
echo Script finished.  Press any key to close this window.
pause >nul
endlocal
