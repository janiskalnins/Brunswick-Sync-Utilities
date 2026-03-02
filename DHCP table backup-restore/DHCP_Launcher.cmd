@echo off
:: ============================================================
::  DHCP Utility Launcher
::  Version : 5.0
::  Calls   : DHCP_Utility.ps1  (must be in the same folder)
::  Compat  : Windows Server 2012 / Windows 8 and newer
::  Encoding: ASCII (ANSI) - NO BOM
:: ============================================================
setlocal EnableDelayedExpansion

:: -- Self-Elevation ------------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  [UAC]  Administrator privileges are required.
    echo  [UAC]  A User Account Control prompt will appear now.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/k \"%~f0\"' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b
)

:: -- Resolve paths -------------------------------------------
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PS_SCRIPT=%SCRIPT_DIR%\DHCP_Utility.ps1"

:: -- Verify PS1 exists ---------------------------------------
if not exist "%PS_SCRIPT%" (
    echo.
    echo  [X] ERROR: DHCP_Utility.ps1 not found.
    echo.
    echo      Expected: %PS_SCRIPT%
    echo.
    echo      Both files must sit in the same folder:
    echo        DHCP_Launcher.cmd
    echo        DHCP_Utility.ps1
    echo.
    pause
    exit /b 1
)

:: ============================================================
:MAIN_MENU
:: ============================================================
cls
echo.
echo  ==================================================
echo.
echo         DHCP Backup ^& Restore Utility
echo.
echo  ==================================================
echo.
echo    What do you want to do today?
echo.
echo    [1]  Backup          --  Export and save DHCP table
echo    [2]  Restore         --  Import DHCP table from backup
echo    [3]  Delete Backups  --  Remove old backup files
echo    [4]  Delete Scope    --  Remove existing DHCP scope(s)
echo    [5]  DHCP Service    --  Start / Stop / Restart DHCP Server
echo    [6]  Exit
echo.
echo  --------------------------------------------------
echo.

set "CHOICE="
set /p "CHOICE=  Enter your choice [1-6]: "
echo.

if "!CHOICE!"=="1" goto :RUN_BACKUP
if "!CHOICE!"=="2" goto :RUN_RESTORE
if "!CHOICE!"=="3" goto :RUN_DELETE
if "!CHOICE!"=="4" goto :RUN_DELETESCOPE
if "!CHOICE!"=="5" goto :RUN_SERVICE
if "!CHOICE!"=="6" goto :EXIT_LAUNCHER

echo  [!] Invalid choice. Please enter 1 through 6.
timeout /t 2 >nul
goto :MAIN_MENU


:: ============================================================
:RUN_BACKUP
:: ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode Backup
if %errorlevel% neq 0 (
    echo.
    echo  [!] PowerShell exited with error code: %errorlevel%
    echo      Check the log file: %SCRIPT_DIR%\dhcp_utility.log
    echo.
    pause
)
goto :MAIN_MENU


:: ============================================================
:RUN_RESTORE
:: ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode Restore
if %errorlevel% neq 0 (
    echo.
    echo  [!] PowerShell exited with error code: %errorlevel%
    echo      Check the log file: %SCRIPT_DIR%\dhcp_utility.log
    echo.
    pause
)
goto :MAIN_MENU


:: ============================================================
:RUN_DELETE
:: ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode Delete
if %errorlevel% neq 0 (
    echo.
    echo  [!] PowerShell exited with error code: %errorlevel%
    echo      Check the log file: %SCRIPT_DIR%\dhcp_utility.log
    echo.
    pause
)
goto :MAIN_MENU


:: ============================================================
:RUN_DELETESCOPE
:: ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode DeleteScope
if %errorlevel% neq 0 (
    echo.
    echo  [!] PowerShell exited with error code: %errorlevel%
    echo      Check the log file: %SCRIPT_DIR%\dhcp_utility.log
    echo.
    pause
)
goto :MAIN_MENU


:: ============================================================
:RUN_SERVICE
:: ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode ServiceManager
if %errorlevel% neq 0 (
    echo.
    echo  [!] PowerShell exited with error code: %errorlevel%
    echo      Check the log file: %SCRIPT_DIR%\dhcp_utility.log
    echo.
    pause
)
goto :MAIN_MENU


:: ============================================================
:EXIT_LAUNCHER
:: ============================================================
cls
echo.
echo  Goodbye.
echo.
endlocal
exit /b 0
