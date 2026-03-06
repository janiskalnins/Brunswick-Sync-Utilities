#Requires -Version 5.1
<#
.SYNOPSIS
    Brunswick Display Controller Reset Utility
.DESCRIPTION
    Kills Process* tasks, manages Explorer windows, optionally syncs
    DeviceManager files, wipes the Configuration.xml, renames the
    computer, and reboots to the Unknown Configuration screen.
    Logs every action to a CSV on the network share.
.NOTES
    * Runs on Windows 10 / 11
    * Self-elevates when not already Administrator
    * ASCII-safe (no Unicode special characters)
    * Safe to run from a network drive
#>

# ======================================================================
#  SELF-ELEVATION
# ======================================================================
$currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin          = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $scriptPath = $MyInvocation.MyCommand.Definition
    $argList    = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    exit
}

# ======================================================================
#  STRICT MODE & ERROR PREFERENCE
# ======================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ======================================================================
#  CONSTANTS
# ======================================================================
$TARGET_PROC_PREFIX   = "Process"
$SERVER_EXE_DIR       = "\\SyncServer\Syncinstall\Updates\Executables\DeviceManager"
$LOG_DIR              = $PSScriptRoot
$LOG_FILE             = Join-Path $LOG_DIR "DisplayController_Reset_Log.csv"
$RANDOM_NAME_LEN      = 8
$RANDOM_NAME_CHARS    = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

# ---- Resolve Brunswick install path (x86 or standard) ----------------
# 32-bit apps install to "Program Files (x86)" on 64-bit Windows,
# and to "Program Files" on 32-bit Windows.  We probe both and use
# whichever base folder exists.  We NEVER create missing directories.
$BRUNSWICK_BASE_X86 = "C:\Program Files (x86)\Brunswick\Sync\SyncInstall\Configuration"
$BRUNSWICK_BASE_X64 = "C:\Program Files\Brunswick\Sync\SyncInstall\Configuration"

if     (Test-Path $BRUNSWICK_BASE_X86) { $BRUNSWICK_BASE = $BRUNSWICK_BASE_X86 }
elseif (Test-Path $BRUNSWICK_BASE_X64) { $BRUNSWICK_BASE = $BRUNSWICK_BASE_X64 }
else                                   { $BRUNSWICK_BASE = $BRUNSWICK_BASE_X86 }  # most common -- shown as expected path

$LOCAL_EXE_DIR = Join-Path $BRUNSWICK_BASE "Processes\DeviceManager\Executable"
$CONFIG_XML    = Join-Path $BRUNSWICK_BASE "Configuration.xml"

# ======================================================================
#  SERVER SAFEGUARD
#  Checked once at startup.  If this machine looks like a server,
#  the destructive steps (4, 5+6, 7, 8, 9) are permanently blocked.
# ======================================================================

# Names that identify a machine as a server -- add more as needed
$SERVER_NAME_PATTERNS = @(
    'SYNCSERVER',
    'SERVER',
    'SRV',
    'SYNC'
)

function Test-IsProtectedMachine {
    $machineName = $env:COMPUTERNAME

    # Check 1: Name pattern match
    foreach ($pattern in $SERVER_NAME_PATTERNS) {
        if ($machineName -like "*$pattern*") {
            return $true
        }
    }

    # Check 2: Windows Server OS edition
    # ProductType: 1=Workstation, 2=Domain Controller, 3=Member Server
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os.ProductType -gt 1) {
            return $true
        }
    } catch {
        try {
            $caption = (Get-CimInstance Win32_OperatingSystem).Caption
            if ($caption -match 'Server') { return $true }
        } catch { }
    }

    return $false
}

function Show-ProtectionBanner {
    Write-Host ""
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "  !!                   SAFEGUARD TRIGGERED                    !!" -ForegroundColor Red
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This machine has been identified as a SERVER or SOURCE machine:" -ForegroundColor Red
    Write-Host ""
    Write-Host "    Computer Name : $($env:COMPUTERNAME)" -ForegroundColor Yellow
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        Write-Host "    OS            : $($os.Caption)" -ForegroundColor Yellow
        Write-Host "    Product Type  : $($os.ProductType)  (1=Workstation, 2=DC, 3=Server)" -ForegroundColor Yellow
    } catch { }
    Write-Host ""
    Write-Host "  The following destructive steps are BLOCKED on this machine:" -ForegroundColor Red
    Write-Host "    Step 3   -- Delete Executable directory contents" -ForegroundColor Red
    Write-Host "    Step 4+5 -- Copy files from SyncServer" -ForegroundColor Red
    Write-Host "    Step 6   -- Delete Configuration.xml" -ForegroundColor Red
    Write-Host "    Step 7   -- Rename this computer" -ForegroundColor Red
    Write-Host "    Step 8   -- Restart this computer" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Steps 1 and 2 remain available (safe / view-only)." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  If this IS a Display Controller that was mis-identified," -ForegroundColor White
    Write-Host "  rename it so it does NOT contain: $($SERVER_NAME_PATTERNS -join ', ')" -ForegroundColor White
    Write-Host "  then re-run this script." -ForegroundColor White
    Write-Host ""
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host ""
}

function Assert-NotProtected {
    param([string]$StepName)
    if ($script:IS_PROTECTED_MACHINE) {
        Write-Host ""
        Write-Host "  [BLOCKED] $StepName is DISABLED -- server/source machine safeguard is active." -ForegroundColor Red
        Write-Log -Step $StepName -Result "BLOCKED" -Detail "Safeguard: $($env:COMPUTERNAME) identified as server/source"
        return $false
    }
    return $true
}

# ======================================================================
#  COLOUR / UI HELPERS
# ======================================================================
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   Brunswick Display Controller Reset Utility" -ForegroundColor Cyan
    Write-Host "   Version 1.0  |  Running as Administrator" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step   { param($n,$msg) Write-Host "  [Step $n] $msg" -ForegroundColor Yellow }
function Write-OK     { param($msg)    Write-Host "  [  OK  ] $msg" -ForegroundColor Green  }
function Write-Info   { param($msg)    Write-Host "  [ INFO ] $msg" -ForegroundColor Cyan   }
function Write-Warn   { param($msg)    Write-Host "  [ WARN ] $msg" -ForegroundColor Magenta}
function Write-Fail   { param($msg)    Write-Host "  [ FAIL ] $msg" -ForegroundColor Red    }
function Write-Skip   { param($msg)    Write-Host "  [ SKIP ] $msg" -ForegroundColor DarkGray}

function Confirm-Continue {
    param([string]$Prompt = "Continue? [Y] Yes  [N] No/Cancel")
    Write-Host ""
    Write-Host "  $Prompt  " -ForegroundColor White -NoNewline
    $key = $null
    while ($key -notin @('Y','N')) {
        $key = (Read-Host).Trim().ToUpper()
        if ($key -eq '') { $key = 'Y' }
    }
    if ($key -eq 'N') {
        Write-Host ""
        Write-Warn "User cancelled.  Exiting."
        Write-Host ""
        exit 0
    }
}

function Ask-YesNo {
    param([string]$Prompt)
    Write-Host "  $Prompt [Y/N]: " -ForegroundColor White -NoNewline
    $key = $null
    while ($key -notin @('Y','N')) {
        $key = (Read-Host).Trim().ToUpper()
    }
    return ($key -eq 'Y')
}

# ======================================================================
#  LOGGING
# ======================================================================
function Write-Log {
    param(
        [string]$Step,
        [string]$Result,
        [string]$Detail = ""
    )

    # Collect identity info once per session (cached in script scope)
    if (-not $script:LogInfoCached) {
        try { $script:LogIP  = (Get-NetIPAddress -AddressFamily IPv4 |
                                Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } |
                                Select-Object -First 1).IPAddress } catch { $script:LogIP = "Unknown" }
        try { $script:LogMAC = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
                                Select-Object -First 1).MacAddress } catch { $script:LogMAC = "Unknown" }
        $script:LogHost  = $env:COMPUTERNAME
        $script:LogInfoCached = $true
    }

    $ts  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $row = "`"$ts`",`"$($script:LogHost)`",`"$($script:LogIP)`",`"$($script:LogMAC)`",`"$Step`",`"$Result`",`"$Detail`""

    # Write header if file does not exist
    if (-not (Test-Path $LOG_FILE)) {
        try {
            "Timestamp,Computer,IP,MAC,Step,Result,Detail" | Out-File -FilePath $LOG_FILE -Encoding ASCII
        } catch {
            Write-Warn "Could not create log file at $LOG_FILE"
        }
    }

    try {
        $row | Out-File -FilePath $LOG_FILE -Encoding ASCII -Append
    } catch {
        Write-Warn "Log write failed: $_"
    }
}

# Initialize log cache flag
$script:LogInfoCached = $false

# ======================================================================
#  STEP FUNCTIONS
# ======================================================================

# --------------------------------------------------
# STEP 1: Kill Process* tasks
# --------------------------------------------------
function Invoke-KillProcessTasks {
    Write-Step 1 "Killing all processes whose name starts with '$TARGET_PROC_PREFIX'..."

    $found = Get-Process | Where-Object { $_.Name -like "$TARGET_PROC_PREFIX*" }
    if (-not $found) {
        Write-Skip "No matching processes found."
        Write-Log -Step "1-KillProcesses" -Result "SKIP" -Detail "No processes starting with $TARGET_PROC_PREFIX"
        return
    }

    foreach ($proc in $found) {
        try {
            Write-Info "Stopping: $($proc.Name)  (PID $($proc.Id))"
            $proc | Stop-Process -Force
            Write-OK   "Stopped $($proc.Name)"
            Write-Log -Step "1-KillProcesses" -Result "OK" -Detail "Stopped $($proc.Name) PID=$($proc.Id)"
        } catch {
            Write-Fail "Could not stop $($proc.Name): $_"
            Write-Log -Step "1-KillProcesses" -Result "FAIL" -Detail "Could not stop $($proc.Name): $_"
        }
    }
}

# --------------------------------------------------
# STEP 2: Open AND Navigate two Explorer windows side-by-side
# --------------------------------------------------
function Invoke-OpenAndNavigateExplorers {
    Write-Step 2 "Opening and navigating two Explorer windows side-by-side..."

    # -- Left window: ALWAYS the local Executable target dir ----------
    # We never create the directory -- if it does not exist we warn
    # the user but still pass the path so they can see where it should be.
    $path1 = $LOCAL_EXE_DIR
    if (-not (Test-Path $path1)) {
        Write-Warn "Local Executable directory not found:"
        Write-Warn "  $path1"
        Write-Warn "Explorer will open to the nearest existing parent folder."
        # Walk up until we find an ancestor that exists, so Explorer
        # does not silently redirect to Desktop or This PC.
        $fallback = $path1
        while ($fallback -and -not (Test-Path $fallback)) {
            $fallback = Split-Path $fallback -Parent
        }
        if ($fallback) { $path1 = $fallback }
    }

    # -- Right window: server source dir, or Network as fallback ------
    $path2       = $SERVER_EXE_DIR
    $path2IsShell = $false
    if (-not (Test-Path $path2)) {
        Write-Warn "Server path not reachable: $SERVER_EXE_DIR"
        Write-Warn "Right window will open to Network neighbourhood."
        $path2       = "shell:NetworkPlacesFolder"
        $path2IsShell = $true
    }

    Write-Info "Left  (TARGET) -> $path1"
    Write-Info "Right (SOURCE) -> $path2"

    try {
        Add-Type -AssemblyName System.Windows.Forms 2>$null

        $screenW = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width
        $screenH = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
        $halfW   = [int]($screenW / 2)

        # Shell.Application.Explore(path) opens a new Explorer window
        # navigated directly to the path without any quoting issues --
        # the COM method receives a native .NET string so spaces in paths
        # like "C:\Program Files\..." are handled correctly.
        $shell      = New-Object -ComObject Shell.Application
        $beforeHWNDs = @($shell.Windows() | ForEach-Object { $_.HWND })

        # ---- Window 1: left (local target) --------------------------
        $shell.Explore($path1)

        $win1     = $null
        $deadline = (Get-Date).AddSeconds(12)
        while (-not $win1 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            $new = @($shell.Windows() |
                Where-Object { $_.HWND -notin $beforeHWNDs -and $_.Name -eq "File Explorer" })
            if ($new.Count -gt 0) { $win1 = $new[0] }
        }

        if ($win1) {
            $win1.Left   = 0
            $win1.Top    = 0
            $win1.Width  = $halfW
            $win1.Height = $screenH
            Write-OK "Left window opened at: $($win1.LocationURL)"
        } else {
            Write-Warn "Left window did not appear within timeout."
        }

        # ---- Window 2: right (server source) ------------------------
        $beforeHWNDs2 = @($shell.Windows() | ForEach-Object { $_.HWND })

        if ($path2IsShell) {
            # shell: namespace URIs are not accepted by Explore() --
            # fall back to Start-Process for the Network folder only.
            Start-Process explorer.exe -ArgumentList $path2
        } else {
            $shell.Explore($path2)
        }

        $win2      = $null
        $deadline2 = (Get-Date).AddSeconds(12)
        while (-not $win2 -and (Get-Date) -lt $deadline2) {
            Start-Sleep -Milliseconds 300
            $new2 = @($shell.Windows() |
                Where-Object { $_.HWND -notin $beforeHWNDs2 -and $_.Name -eq "File Explorer" })
            if ($new2.Count -gt 0) { $win2 = $new2[0] }
        }

        if ($win2) {
            $win2.Left   = $halfW
            $win2.Top    = 0
            $win2.Width  = $halfW
            $win2.Height = $screenH
            Write-OK "Right window opened at: $($win2.LocationURL)"
        } else {
            Write-Warn "Right window did not appear within timeout."
        }

        Write-Log -Step "2-OpenAndNavigate" -Result "OK" -Detail "Left=$path1  Right=$path2"

    } catch {
        Write-Fail "Explorer step failed: $_"
        Write-Log -Step "2-OpenAndNavigate" -Result "FAIL" -Detail "$_"
    }
}

# --------------------------------------------------
# STEP 4 (Optional): Delete contents of Executable dir
# --------------------------------------------------
function Invoke-ClearLocalExeDir {
    Write-Step 3 "(Optional) Deleting contents of: $LOCAL_EXE_DIR"

    if (-not (Test-Path $LOCAL_EXE_DIR)) {
        Write-Warn "Directory not found: $LOCAL_EXE_DIR"
        Write-Log -Step "4-ClearExeDir" -Result "WARN" -Detail "Directory not found"
        return
    }

    try {
        $items = Get-ChildItem -Path $LOCAL_EXE_DIR -Force
        if ($items.Count -eq 0) {
            Write-Skip "Directory is already empty."
            Write-Log -Step "4-ClearExeDir" -Result "SKIP" -Detail "Already empty"
            return
        }
        $items | Remove-Item -Recurse -Force
        Write-OK "Cleared $($items.Count) item(s) from the Executable directory."
        Write-Log -Step "4-ClearExeDir" -Result "OK" -Detail "Removed $($items.Count) items"
    } catch {
        Write-Fail "Failed to clear directory: $_"
        Write-Log -Step "4-ClearExeDir" -Result "FAIL" -Detail "$_"
    }
}

# --------------------------------------------------
# STEP 5+6 (Optional): Copy from server to local
# --------------------------------------------------
function Invoke-CopyFromServer {
    Write-Step "4+5" "(Optional) Copying DeviceManager files from server to local Executable dir..."

    # Check network prerequisites
    Write-Info "Checking network connectivity to SyncServer..."
    if (-not (Test-Connection -ComputerName "SyncServer" -Count 1 -Quiet)) {
        Write-Warn "Cannot reach SyncServer.  Check:"
        Write-Warn "  - Network Discovery is ENABLED"
        Write-Warn "  - Password Protected Sharing is DISABLED"
        Write-Warn "  - VPN / firewall is not blocking the share"
        Write-Log -Step "5+6-CopyFiles" -Result "FAIL" -Detail "Cannot reach SyncServer"
        Confirm-Continue "Try to copy anyway? [Y] Yes  [N] Skip this step"
    }

    if (-not (Test-Path $SERVER_EXE_DIR)) {
        Write-Fail "Server path not accessible: $SERVER_EXE_DIR"
        Write-Log -Step "5+6-CopyFiles" -Result "FAIL" -Detail "Server path not found"
        return
    }
    if (-not (Test-Path $LOCAL_EXE_DIR)) {
        Write-Info "Creating local directory: $LOCAL_EXE_DIR"
        New-Item -ItemType Directory -Path $LOCAL_EXE_DIR -Force | Out-Null
    }

    try {
        $srcItems = Get-ChildItem -Path $SERVER_EXE_DIR -Force
        if ($srcItems.Count -eq 0) {
            Write-Warn "Source directory on server appears to be empty."
            Write-Log -Step "5+6-CopyFiles" -Result "WARN" -Detail "Source empty"
            return
        }
        Write-Info "Copying $($srcItems.Count) item(s)..."
        Copy-Item -Path "$SERVER_EXE_DIR\*" -Destination $LOCAL_EXE_DIR -Recurse -Force
        Write-OK "Copy complete."
        Write-Log -Step "5+6-CopyFiles" -Result "OK" -Detail "Copied $($srcItems.Count) items from $SERVER_EXE_DIR"
    } catch {
        Write-Fail "Copy failed: $_"
        Write-Log -Step "5+6-CopyFiles" -Result "FAIL" -Detail "$_"
    }
}

# --------------------------------------------------
# STEP 7: Delete Configuration.xml
# --------------------------------------------------
function Invoke-DeleteConfig {
    Write-Step 6 "Deleting Configuration.xml..."
    Write-Info "Target: $CONFIG_XML"

    if (-not (Test-Path $CONFIG_XML)) {
        Write-Skip "Configuration.xml not found (may already be deleted)."
        Write-Log -Step "7-DeleteConfig" -Result "SKIP" -Detail "File not found"
        return
    }

    try {
        Remove-Item -Path $CONFIG_XML -Force
        Write-OK "Configuration.xml deleted."
        Write-Log -Step "7-DeleteConfig" -Result "OK" -Detail "$CONFIG_XML"
    } catch {
        Write-Fail "Delete failed: $_"
        Write-Log -Step "7-DeleteConfig" -Result "FAIL" -Detail "$_"
    }
}

# --------------------------------------------------
# STEP 8: Rename computer
# --------------------------------------------------
function Invoke-RenameComputer {
    Write-Step 7 "Renaming this Display Controller to a random name..."

    $rng      = New-Object System.Random
    $newName  = -join (1..$RANDOM_NAME_LEN | ForEach-Object {
        $RANDOM_NAME_CHARS[$rng.Next(0, $RANDOM_NAME_CHARS.Length)]
    })

    $oldName = $env:COMPUTERNAME
    Write-Info "Current name : $oldName"
    Write-Info "New name     : $newName"

    try {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        Write-OK "Computer renamed to $newName (takes effect after reboot)."
        Write-Log -Step "8-RenameComputer" -Result "OK" -Detail "OldName=$oldName  NewName=$newName"
    } catch {
        Write-Fail "Rename failed: $_"
        Write-Log -Step "8-RenameComputer" -Result "FAIL" -Detail "$_"
    }
}

# --------------------------------------------------
# STEP 9: Restart
# --------------------------------------------------
function Invoke-RestartNow {
    Write-Step 8 "Restarting the Display Controller..."
    Write-Info "The machine will reboot in 10 seconds."
    Write-Info "It should boot to the Unknown Configuration screen."
    Write-Log -Step "9-Restart" -Result "OK" -Detail "Reboot initiated"

    for ($i = 10; $i -ge 1; $i--) {
        Write-Host "`r  Rebooting in $i second(s)...  " -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Restart-Computer -Force
}

# ======================================================================
#  AUTO RESET (secret "all" workflow)
#  Triggered by typing "all" at the opening prompt.
#  Silently executes Steps 1, 6, 7, and 8 without any user prompts.
# ======================================================================
function Invoke-AutoReset {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor DarkGray
    Write-Host "   Brunswick Display Controller -- Auto Reset" -ForegroundColor DarkGray
    Write-Host "  ============================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Log -Step "AUTO-START" -Result "OK" -Detail "Auto reset initiated on $($env:COMPUTERNAME)"

    # Guard: safeguard still applies in auto mode
    if ($script:IS_PROTECTED_MACHINE) {
        Write-Fail "AUTO RESET ABORTED -- server/source machine safeguard is active."
        Write-Log -Step "AUTO-START" -Result "BLOCKED" -Detail "Safeguard prevented auto reset on $($env:COMPUTERNAME)"
        Write-Host ""
        exit 1
    }

    # -- Auto Step 1: Kill Process* tasks ------------------------------
    Write-Host "  [Auto 1/4] Killing Process* tasks..." -ForegroundColor Yellow
    Invoke-KillProcessTasks
    Start-Sleep -Milliseconds 500

    # -- Auto Step 2: Delete Configuration.xml ------------------------
    Write-Host ""
    Write-Host "  [Auto 2/4] Deleting Configuration.xml..." -ForegroundColor Yellow
    Invoke-DeleteConfig
    Start-Sleep -Milliseconds 500

    # -- Auto Step 3: Rename computer ---------------------------------
    Write-Host ""
    Write-Host "  [Auto 3/4] Renaming computer..." -ForegroundColor Yellow
    Invoke-RenameComputer
    Start-Sleep -Milliseconds 500

    # -- Auto Step 4: Restart -----------------------------------------
    Write-Host ""
    Write-Host "  [Auto 4/4] Restarting..." -ForegroundColor Yellow
    Write-Log -Step "AUTO-COMPLETE" -Result "OK" -Detail "All auto steps finished. Rebooting."

    for ($i = 10; $i -ge 1; $i--) {
        Write-Host "`r  Rebooting in $i second(s)...  " -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Restart-Computer -Force
}

# ======================================================================
#  MAIN FLOW
# ======================================================================

# Load Windows.Forms for screen resolution query
Add-Type -AssemblyName System.Windows.Forms 2>$null

# ---- Run the server/source safeguard check BEFORE anything else ----
$script:IS_PROTECTED_MACHINE = Test-IsProtectedMachine

Show-Banner

if ($script:IS_PROTECTED_MACHINE) {
    Show-ProtectionBanner
    Write-Log -Step "STARTUP" -Result "SAFEGUARD" -Detail "Machine identified as server/source. Destructive steps blocked."
} else {
    Write-Host "  Safeguard check passed -- this machine does not appear to be a server." -ForegroundColor Green
    Write-Host ""
}

Write-Host "  This utility will reset a Brunswick Display Controller." -ForegroundColor White
Write-Host "  You will be prompted before each optional step." -ForegroundColor White
Write-Host "  Type N at any prompt to cancel the entire script." -ForegroundColor White
Write-Host ""
Write-Info "Log file: $LOG_FILE"
Write-Host ""
# ---- Opening prompt -- also intercepts the secret "all" keyword ----------
Write-Host "  Ready to begin the reset process? [Y] Yes  [N] Cancel  " -ForegroundColor White -NoNewline
$script:AUTO_MODE = $false
$openKey = $null
while ($openKey -notin @('Y','N','ALL')) {
    $openKey = (Read-Host).Trim().ToUpper()
    if ($openKey -eq '') { $openKey = 'Y' }
}
if ($openKey -eq 'N') {
    Write-Warn "User cancelled.  Exiting."
    exit 0
}
if ($openKey -eq 'ALL') {
    $script:AUTO_MODE = $true
}

# ---- Branch: auto mode jumps straight to silent execution ------------
if ($script:AUTO_MODE) {
    Invoke-AutoReset
    exit 0
}

# ---- STEP 1 -------------------------------------------------------
Write-Host ""
Invoke-KillProcessTasks

# ---- STEP 2: Open and Navigate Explorers --------------------------
Write-Host ""
if (Ask-YesNo "Step 2: Open and navigate two Explorer windows side-by-side?") {
    Invoke-OpenAndNavigateExplorers
} else { Write-Skip "Step 2 skipped." }

# ---- STEP 3 (optional) --------------------------------------------
Write-Host ""
if (-not (Assert-NotProtected "3-ClearExeDir")) {
    Write-Skip "Step 3 blocked by server/source safeguard."
} else {
    Write-Warn "STEP 3 will permanently delete all files in:"
    Write-Warn "  $LOCAL_EXE_DIR"
    if (Ask-YesNo "Step 3 (Optional): Delete contents of the local Executable directory?") {
        Invoke-ClearLocalExeDir
    } else { Write-Skip "Step 3 skipped." }
}

# ---- STEPS 4+5 (optional) -----------------------------------------
Write-Host ""
if (-not (Assert-NotProtected "4+5-CopyFiles")) {
    Write-Skip "Steps 4+5 blocked by server/source safeguard."
} else {
    Write-Info "NOTE for Steps 4+5: Network Discovery must be ON and"
    Write-Info "Password Protected Sharing must be OFF on this machine."
    Write-Host ""
    if (Ask-YesNo "Steps 4+5 (Optional): Copy DeviceManager files from SyncServer?") {
        Invoke-CopyFromServer
    } else { Write-Skip "Steps 4+5 skipped." }
}

# ---- STEP 6 -------------------------------------------------------
Write-Host ""
if (-not (Assert-NotProtected "6-DeleteConfig")) {
    Write-Skip "Step 6 blocked by server/source safeguard."
} else {
    Write-Warn "STEP 6 will permanently delete:"
    Write-Warn "  $CONFIG_XML"
    Confirm-Continue "Proceed with Step 6? [Y] Yes  [N] Cancel"
    Invoke-DeleteConfig
}

# ---- STEP 7 -------------------------------------------------------
Write-Host ""
if (-not (Assert-NotProtected "7-RenameComputer")) {
    Write-Skip "Step 7 blocked by server/source safeguard."
} else {
    Confirm-Continue "Proceed with Step 7 (rename computer to random name)? [Y] Yes  [N] Cancel"
    Invoke-RenameComputer
}

# ---- STEP 8 -------------------------------------------------------
Write-Host ""
if (-not (Assert-NotProtected "8-Restart")) {
    Write-Skip "Step 8 blocked by server/source safeguard."
} else {
    Write-Warn "STEP 8: The computer will REBOOT immediately after confirmation."
    if (Ask-YesNo "Step 8: Restart the Display Controller now?") {
        Invoke-RestartNow
    } else {
        Write-Skip "Reboot skipped.  Please restart manually for changes to take effect."
        Write-Log -Step "8-Restart" -Result "SKIP" -Detail "User chose not to reboot"
    }
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   Reset process complete.  Check the log for details:" -ForegroundColor Cyan
Write-Host "   $LOG_FILE" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
