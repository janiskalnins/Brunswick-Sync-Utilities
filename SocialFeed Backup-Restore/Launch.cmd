@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  Sync SocialFeed and TextEffects Backup/Restore Script
::  CMD Launcher - Compatible with Windows Server 2016+
::  - Self-elevating via UAC
::  - Self-unblocking (removes Zone.Identifier ADS)
:: ============================================================

title Sync SocialFeed and TextEffects Backup/Restore

:: ----------------------------------------------------------------
:: Resolve script directory. %~dp0 always points to the .cmd file
:: location, even after a UAC-elevated relaunch.
:: ----------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "SELF=%~f0"
set "PS_SCRIPT=%SCRIPT_DIR%\SyncBackupRestore.ps1"
set "PS_JSON=%SCRIPT_DIR%\SyncBackupRestore.json"

:: ----------------------------------------------------------------
:: STEP 1 - Verify the PowerShell script is present BEFORE we try
:: to elevate, so the user gets a clear error immediately.
:: ----------------------------------------------------------------
if not exist "%PS_SCRIPT%" (
    echo.
    echo  [ERROR] Cannot find SyncBackupRestore.ps1 in:
    echo          %SCRIPT_DIR%
    echo.
    echo  Please ensure both files are in the same folder.
    echo.
    pause
    exit /b 1
)

:: ----------------------------------------------------------------
:: STEP 2 - Detect PowerShell executable.
:: Prefers pwsh.exe (PowerShell 7+), falls back to powershell.exe
:: (Windows PowerShell 3/4/5 - standard on Server 2016).
:: ----------------------------------------------------------------
set "PS_EXE="
set "PS_VER=unknown"

where pwsh.exe >nul 2>&1
if %errorlevel%==0 (
    set "PS_EXE=pwsh.exe"
    for /f "tokens=*" %%v in ('pwsh.exe -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "PS_VER=%%v"
    goto :ps_found
)

where powershell.exe >nul 2>&1
if %errorlevel%==0 (
    set "PS_EXE=powershell.exe"
    for /f "tokens=*" %%v in ('powershell.exe -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "PS_VER=%%v"
    goto :ps_found
)

echo.
echo  [ERROR] PowerShell was not found on this system.
echo  Please install PowerShell and try again.
echo.
pause
exit /b 1

:ps_found

:: ----------------------------------------------------------------
:: STEP 3 - UNBLOCK SCRIPT FILES
::
:: Files downloaded from the internet (browser, email, USB copied
:: from a network share) carry a hidden Zone.Identifier alternate
:: data stream that Windows uses to flag them as "untrusted". This
:: causes:
::   - SmartScreen "Unknown publisher" warning on .cmd/.exe files
::   - PowerShell ExecutionPolicy blocking .ps1 files
::   - UAC showing "Unknown publisher" instead of the app name
::
:: Fix: use PowerShell's Unblock-File cmdlet (available PS 3.0+)
:: to strip the Zone.Identifier ADS from all script files.
:: This is equivalent to checking "Unblock" in file Properties.
::
:: We run this BEFORE the elevation check so the files are clean
:: regardless of whether UAC is triggered.
::
:: Failures are silenced (-ErrorAction SilentlyContinue) because:
::   - File may already be unblocked (no ADS present) - not an error
::   - Unblock-File itself requires no special privileges
::   - If it fails, -ExecutionPolicy Bypass still lets PS run
:: ----------------------------------------------------------------

echo.
echo  ============================================================
echo   Sync SocialFeed ^& TextEffects Backup/Restore Script
echo  ============================================================
echo.
echo  [~] Checking file trust status...

:: Build a PS command that unblocks all known script files.
:: Uses $env: variables to safely handle spaces in paths.
set "UNBLOCK_CMD=@('%SELF%','%PS_SCRIPT%','%PS_JSON%') | ForEach-Object { if (Test-Path $_) { Unblock-File -Path $_ -ErrorAction SilentlyContinue } }"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "%UNBLOCK_CMD%" >nul 2>&1

if %errorlevel%==0 (
    echo  [OK] File trust status verified.
) else (
    echo  [~] Could not verify file trust status - continuing anyway.
)

:: ----------------------------------------------------------------
:: STEP 4 - Elevation check and self-elevation.
::
:: Done AFTER unblocking so the relaunched elevated process also
:: benefits from the now-clean Zone.Identifier state.
::
:: Quoting strategy for the relaunch argument:
::   $env:SELF is read by PowerShell directly from the environment
::   variable - CMD never expands it inside the PS string, so spaces
::   in paths cannot break it. [char]34 = literal " character.
:: ----------------------------------------------------------------

if defined ELEVATED_RELAUNCH goto :already_elevated

net session >nul 2>&1
if %errorlevel%==0 goto :already_elevated

:: -- Not elevated: attempt UAC self-elevation --------------------
echo.
echo  [!] Administrator privileges are required.
echo      A UAC prompt will appear - please click Yes to continue.
echo.

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "$a='/C set ELEVATED_RELAUNCH=1 && ' + [char]34 + $env:SELF + [char]34; Start-Process $env:ComSpec -ArgumentList $a -Verb RunAs -Wait" ^
    >nul 2>&1

set "UAC_RESULT=%errorlevel%"

if %UAC_RESULT%==0 (
    endlocal
    exit /b 0
)

:: -- UAC declined or disabled ------------------------------------
echo.
echo  [WARNING] Could not elevate automatically.
echo            UAC may be disabled, or you clicked "No".
echo.
echo    1  -  Exit. Then right-click Launch.cmd and choose
echo           "Run as administrator" to retry with elevation.
echo    2  -  Continue WITHOUT elevation. Note: write operations
echo           to "Program Files" will likely fail.
echo.
choice /C 12 /N /M "  Your choice [1=Exit  2=Continue unelevated]: "
if errorlevel 2 (
    echo.
    echo  [WARNING] Continuing without elevated privileges.
    echo            Some operations may fail.
    echo.
    goto :run_script
)
echo.
echo  Exiting. Right-click Launch.cmd -> "Run as administrator".
echo.
pause
endlocal
exit /b 1

:already_elevated
echo.
echo  ============================================================
echo   Sync SocialFeed ^& TextEffects Backup/Restore Script
echo  ============================================================
echo   PowerShell : %PS_EXE%  ^(version %PS_VER%^)
echo   Script     : %PS_SCRIPT%
echo   Elevated   : Yes
echo  ============================================================
echo.

:run_script
:: ----------------------------------------------------------------
:: STEP 5 - Launch the PowerShell script.
:: -NonInteractive intentionally omitted so Read-Host works.
:: ScriptRoot passed explicitly so the .ps1 always resolves its
:: Backup folder and config correctly regardless of CWD.
:: ----------------------------------------------------------------
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass ^
    -File "%PS_SCRIPT%" ^
    -ScriptRoot "%SCRIPT_DIR%"

set "PS_EXIT=%errorlevel%"

echo.
if %PS_EXIT%==0 (
    echo  [OK] Script completed successfully.
) else (
    echo  [ERROR] Script exited with code: %PS_EXIT%
    echo          Check SyncBackupRestore.log for details.
)
echo.
pause
endlocal
exit /b %PS_EXIT%
