#Requires -Version 3.0
<#
.SYNOPSIS
    Sync SocialFeed and TextEffects Backup/Restore Script

.DESCRIPTION
    Creates and restores versioned backups of SocialFeed.txt and TextEffects.txt
    from Brunswick Sync installation. Compatible with PowerShell 3.0+ and
    Windows Server 2016+. Resilient against regional/locale settings.

.PARAMETER ScriptRoot
    Directory where the script and Backup folder reside. Passed by CMD launcher.
#>

[CmdletBinding()]
param(
    [string]$ScriptRoot = ""
)

# ============================================================
#  REGION: Initialization & Culture Safety
# ============================================================

# Force invariant culture to avoid regional setting issues
# (decimal separators, date formats, etc.)
[System.Threading.Thread]::CurrentThread.CurrentCulture   = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture

# Resolve script root robustly across PS versions
if ([string]::IsNullOrEmpty($ScriptRoot)) {
    if ($PSScriptRoot) {
        $ScriptRoot = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $ScriptRoot = (Get-Location).Path
    }
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ============================================================
#  REGION: Logging
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","OK","DIVIDER")]
        [string]$Level = "INFO"
    )
    $ts      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = if ($Level -eq "DIVIDER") { "=" * 64 } else { "[$ts] [$Level] $Message" }

    try {
        # Guard: $LogFile may not be set yet if Write-Log is called
        # during early init (e.g. from Invoke-SelfUnblock). Skip
        # silently - the message is not lost, the script continues.
        if (-not [string]::IsNullOrEmpty($LogFile)) {
            Add-Content -Path $LogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {
        # Non-fatal - logging failure should not stop the script
    }
}

function Write-LogDivider { Write-Log -Message "" -Level "DIVIDER" }

# ============================================================
#  REGION: Self-Unblock (Zone.Identifier removal)
#
#  Files downloaded from the internet carry a hidden NTFS
#  alternate data stream called Zone.Identifier that Windows
#  uses to flag them as untrusted. This causes:
#    - "Unknown publisher" warnings in UAC dialogs
#    - ExecutionPolicy blocking .ps1 files from running
#    - SmartScreen warnings on .cmd / .exe files
#
#  This block strips that stream from this script and any
#  companion files (config, launcher) so all subsequent
#  operations - including the UAC relaunch - are treated as
#  coming from a trusted local file.
#
#  Unblock-File is available since PowerShell 3.0 and needs
#  no special privileges. Errors are silenced because:
#    - The file may already be unblocked (normal case)
#    - A failure here does not prevent the script from running
#      (ExecutionPolicy Bypass in the launcher covers it)
#
#  Must run BEFORE the self-elevation block so that the
#  elevated re-launch inherits the clean trust state.
# ============================================================

function Invoke-SelfUnblock {
    # Collect all files that belong to this script package
    $candidates = @(
        $MyInvocation.ScriptName                          # this .ps1
        $PSCommandPath                                     # alternate path ref
        (Join-Path $ScriptRoot 'SyncBackupRestore.ps1')
        (Join-Path $ScriptRoot 'SyncBackupRestore.json')
        (Join-Path $ScriptRoot 'Launch.cmd')
    )

    $unblocked = 0
    $skipped   = 0

    foreach ($path in $candidates) {
        if ([string]::IsNullOrEmpty($path)) { continue }
        if (-not (Test-Path -LiteralPath $path))  { continue }

        try {
            # Check whether a Zone.Identifier stream actually exists
            # before calling Unblock-File - avoids noise in the log
            # when files are already trusted.
            $streamPath = "$path`:Zone.Identifier"
            $hasZone    = $false

            # Get-Item with -Stream is PS 3.0+ on NTFS only;
            # wrap in try/catch for FAT/exFAT drives (USB sticks)
            try {
                $stream  = Get-Item -LiteralPath $streamPath `
                               -ErrorAction Stop 2>$null
                $hasZone = ($null -ne $stream)
            } catch {
                $hasZone = $false
            }

            if ($hasZone) {
                Unblock-File -LiteralPath $path -ErrorAction Stop
                Write-Log "Unblocked (Zone.Identifier removed): $path" -Level "OK"
                $unblocked++
            } else {
                $skipped++
            }
        } catch {
            # Non-fatal: log the warning but keep going
            Write-Log "Could not unblock ${path}: $_" -Level "WARN"
        }
    }

    if ($unblocked -gt 0) {
        Write-Host ""
        Write-Host "  [OK] Removed 'downloaded from internet' mark from $unblocked file(s)." `
            -ForegroundColor Green
        Write-Host "       (Zone.Identifier alternate data stream cleared)" `
            -ForegroundColor DarkGray
    }
}

Invoke-SelfUnblock

# ============================================================
#  REGION: Self-Elevation
#  If the script is not running as Administrator it will try to
#  relaunch itself elevated via UAC.  This is a secondary safety
#  net - the CMD launcher already attempts elevation, but the .ps1
#  can also be run directly (e.g. from the PowerShell ISE or
#  right-click > Run with PowerShell).
#
#  Logic:
#    1. Check WindowsPrincipal for Administrator role.
#    2. If not elevated, build a Start-Process -Verb RunAs call
#       that relaunches the same .ps1 with the same -ScriptRoot.
#    3. Exit the current (unelevated) process so there is no
#       duplicate window running in parallel.
#    4. If Start-Process itself throws (UAC disabled / declined),
#       catch the error and warn the user but continue - write
#       operations may fail later and the log will capture why.
# ============================================================

function Test-IsAdmin {
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        # If the check itself fails (unusual), assume not admin to be safe
        return $false
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "   [!] Script is not running as Administrator." -ForegroundColor Yellow
    Write-Host "       Attempting to self-elevate via UAC..." -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host ""

    # Determine which PowerShell executable to relaunch with.
    # Use the same exe that is running right now.
    $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    # Resolve this script's path as reliably as possible
    $thisScript = $null
    if ($MyInvocation.MyCommand.Path) {
        $thisScript = $MyInvocation.MyCommand.Path
    } elseif ($PSCommandPath) {
        $thisScript = $PSCommandPath
    }

    if ($thisScript -and (Test-Path $thisScript)) {
        # Build argument list, preserving ScriptRoot so Backup/log
        # paths are still relative to the original script location.
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$thisScript`" -ScriptRoot `"$ScriptRoot`""

        try {
            $proc = Start-Process `
                -FilePath    $psExe `
                -ArgumentList $argList `
                -Verb        RunAs `
                -PassThru

            if ($proc) {
                # Wait for the elevated window to finish, then exit
                # this unelevated instance so there is no duplicate.
                $proc.WaitForExit()
                exit $proc.ExitCode
            }
        } catch {
            # Start-Process throws when UAC prompt is declined or
            # when UAC is fully disabled (common on some servers).
            Write-Host ""
            Write-Host "  [WARNING] Self-elevation failed or was declined." -ForegroundColor Yellow
            Write-Host "            Error: $_" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Continuing without elevation." -ForegroundColor Yellow
            Write-Host "  Write operations to Program Files may fail." -ForegroundColor Yellow
            Write-Host ""
            # Small pause so the user can read the warning before
            # the screen is cleared by the main menu.
            Start-Sleep -Seconds 3
        }
    } else {
        # Script path could not be determined (e.g. pasted into ISE
        # interactive console).  Cannot relaunch - warn and proceed.
        Write-Host "  [WARNING] Could not determine script path for relaunch." -ForegroundColor Yellow
        Write-Host "            Please close this window and run Launch.cmd" -ForegroundColor Yellow
        Write-Host "            as Administrator instead." -ForegroundColor Yellow
        Write-Host ""
        Start-Sleep -Seconds 3
    }
}

# ============================================================
#  REGION: Constants & Configuration
# ============================================================

$SCRIPT_TITLE   = "Sync SocialFeed and TextEffects Backup/Restore Script"
$SCRIPT_VERSION = "1.1"

# Config file - auto-created with defaults if missing
$ConfigFile  = Join-Path $ScriptRoot "SyncBackupRestore.json"
$BackupRoot  = Join-Path $ScriptRoot "Backup"
$LogFile     = Join-Path $ScriptRoot "SyncBackupRestore.log"

# Date/time format for backup folder names (dd.MM.yyyy-HH.mm)
$FOLDER_DATE_FORMAT = "dd.MM.yyyy-HH.mm"

# Default config values
$DefaultConfig = [ordered]@{
    SourceFolder       = "C:\Program Files (x86)\Brunswick\Sync\SyncInstall\Content\ScoringMaterials"
    FilesToBackup      = @("SocialFeed.txt", "TextEffects.txt")
    MaxBackupVersions  = 3
    BackupFolderName   = "Backup"
    LogFileName        = "SyncBackupRestore.log"
}

# ============================================================
#  REGION: Console Helpers
# ============================================================

function Write-Header {
    param([string]$Text)
    $width = 64
    $line  = "=" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    $pad = [Math]::Max(0, [Math]::Floor(($width - $Text.Length) / 2))
    Write-Host (" " * $pad + $Text) -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "  -- $Text --" -ForegroundColor Yellow
    Write-Host ""
}

function Write-Info    { param([string]$m) Write-Host "  [i] $m" -ForegroundColor Cyan    }
function Write-Success { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green  }
function Write-Warn    { param([string]$m) Write-Host "  [!] $m" -ForegroundColor Yellow  }
function Write-Err     { param([string]$m) Write-Host "  [X] $m" -ForegroundColor Red     }
function Write-Detail  { param([string]$m) Write-Host "      $m" -ForegroundColor Gray    }

function Read-YesNo {
    param([string]$Prompt, [string]$Default = "Y")
    $hint = if ($Default -eq "Y") { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        Write-Host "  $Prompt $hint : " -NoNewline -ForegroundColor White
        $raw = Read-Host
        if ([string]::IsNullOrWhiteSpace($raw)) { return ($Default -eq "Y") }
        switch ($raw.Trim().ToUpper()) {
            "Y" { return $true  }
            "N" { return $false }
            default { Write-Warn "Please enter Y or N." }
        }
    }
}

function Pause-ForUser {
    param([string]$Message = "Press Enter to continue...")
    Write-Host ""
    Write-Host "  $Message" -ForegroundColor DarkGray
    $null = Read-Host
}

# ============================================================
#  REGION: Configuration Management
# ============================================================

function Load-Config {
    if (Test-Path $ConfigFile) {
        try {
            $raw = Get-Content $ConfigFile -Raw -Encoding UTF8
            # Parse JSON - compatible with PS 3/4 (no ConvertFrom-Json depth param needed for simple objects)
            $parsed = $raw | ConvertFrom-Json
            Write-Log "Configuration loaded from: $ConfigFile"

            # Merge with defaults for any missing keys
            $cfg = [ordered]@{}
            foreach ($key in $DefaultConfig.Keys) {
                if ($parsed.PSObject.Properties.Name -contains $key) {
                    $cfg[$key] = $parsed.$key
                } else {
                    $cfg[$key] = $DefaultConfig[$key]
                }
            }
            return $cfg
        } catch {
            Write-Warn "Config file parse error - using defaults. ($_)"
            Write-Log "Config parse error: $_" -Level "WARN"
        }
    }

    # Write defaults to disk
    try {
        $DefaultConfig | ConvertTo-Json -Depth 4 | Set-Content $ConfigFile -Encoding UTF8
        Write-Log "Default configuration written to: $ConfigFile"
    } catch {
        Write-Log "Could not write default config: $_" -Level "WARN"
    }
    return $DefaultConfig
}

# ============================================================
#  REGION: Backup Discovery
# ============================================================

function Get-BackupList {
    param([hashtable]$Config)

    $backups = @()

    if (-not (Test-Path $BackupRoot)) {
        return $backups
    }

    $dirs = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending   # newest first (lex sort works for our format)

    foreach ($dir in $dirs) {
        # Try to parse folder name as date
        $dt = $null
        try {
            $dt = [datetime]::ParseExact($dir.Name, $FOLDER_DATE_FORMAT,
                  [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            # Skip folders that don't match our naming convention
            continue
        }

        # Check which target files exist in this backup
        $filesFound = @()
        foreach ($f in $Config.FilesToBackup) {
            $fp = Join-Path $dir.FullName $f
            if (Test-Path $fp) { $filesFound += $f }
        }

        if ($filesFound.Count -gt 0) {
            $backups += [PSCustomObject]@{
                FolderName = $dir.Name
                FullPath   = $dir.FullName
                DateTime   = $dt
                Files      = $filesFound
            }
        }
    }

    return $backups
}

# ============================================================
#  REGION: Status Display
# ============================================================

function Show-BackupStatus {
    param(
        [array]$Backups,
        [hashtable]$Config
    )

    Write-Section "Current Backup Status"
    Write-Info "Script ran at : $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
    Write-Info "Backup folder : $BackupRoot"
    Write-Host ""

    if ($Backups.Count -eq 0) {
        Write-Warn "No backups found."
        Write-Log "Status check: no backups found."
    } else {
        Write-Info "Found $($Backups.Count) backup version(s):"
        Write-Host ""
        $i = 1
        foreach ($b in $Backups) {
            $fileList = (@($b.Files)) -join ", "
            Write-Host ("  {0,2}. {1}   [{2}]" -f $i, $b.FolderName, $fileList) -ForegroundColor White
            $i++
        }
        Write-Log "Status check: $($Backups.Count) backup(s) found."
    }
    Write-Host ""
}

# ============================================================
#  REGION: Backup Process
# ============================================================

function Invoke-Backup {
    param([hashtable]$Config)

    Write-Section "Backup Process"
    Write-Log "--- Backup process started ---"

    $src = $Config.SourceFolder

    # Check source folder exists
    if (-not (Test-Path $src)) {
        Write-Err "Source folder not found:"
        Write-Detail $src
        Write-Log "Source folder not found: $src" -Level "ERROR"

        $existingBackups = @(Get-BackupList -Config $Config)
        if ($existingBackups.Count -gt 0) {
            Write-Warn "Would you like to restore from an existing backup instead?"
            if (Read-YesNo -Prompt "Switch to Restore mode?" -Default "Y") {
                Invoke-Restore -Config $Config
                return
            }
        } else {
            Write-Warn "No backups available to restore from either."
        }
        Write-Log "Backup aborted - source not found." -Level "ERROR"
        return
    }

    # Check which source files exist
    $filesToCopy   = @()
    $filesMissing  = @()

    foreach ($f in $Config.FilesToBackup) {
        $fp = Join-Path $src $f
        if (Test-Path $fp) {
            $filesToCopy += $f
        } else {
            $filesMissing += $f
        }
    }

    if ($filesMissing.Count -gt 0) {
        Write-Warn "The following source file(s) were NOT found:"
        foreach ($f in $filesMissing) {
            Write-Detail "  Missing: $(Join-Path $src $f)"
            Write-Log "Source file missing: $f" -Level "WARN"
        }
    }

    if ($filesToCopy.Count -eq 0) {
        Write-Err "None of the target files were found in source. Cannot create backup."
        Write-Log "Backup aborted - no source files found." -Level "ERROR"

        $existingBackups = @(Get-BackupList -Config $Config)
        if ($existingBackups.Count -gt 0) {
            if (Read-YesNo -Prompt "Switch to Restore mode?" -Default "Y") {
                Invoke-Restore -Config $Config
            }
        }
        return
    }

    # Create timestamped backup subfolder
    $folderName = Get-Date -Format $FOLDER_DATE_FORMAT
    $destFolder = Join-Path $BackupRoot $folderName

    # Ensure Backup root exists
    if (-not (Test-Path $BackupRoot)) {
        try {
            New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
            Write-Info "Created backup root folder: $BackupRoot"
            Write-Log "Created backup root: $BackupRoot"
        } catch {
            Write-Err "Could not create backup folder: $_"
            Write-Log "Failed to create backup root: $_" -Level "ERROR"
            return
        }
    }

    # Create timestamped subfolder
    try {
        New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
        Write-Info "Backup destination: $destFolder"
        Write-Log "Backup destination created: $destFolder"
    } catch {
        Write-Err "Could not create timestamped subfolder: $_"
        Write-Log "Failed to create subfolder: $_" -Level "ERROR"
        return
    }

    # Copy files
    $copied  = 0
    $failed  = 0
    foreach ($f in $filesToCopy) {
        $srcFile  = Join-Path $src $f
        $destFile = Join-Path $destFolder $f
        try {
            Copy-Item -LiteralPath $srcFile -Destination $destFile -Force
            $size = (Get-Item $destFile).Length
            Write-Success "Backed up: $f  ($size bytes)"
            Write-Log "Backed up: $f -> $destFile  ($size bytes)" -Level "OK"
            $copied++
        } catch {
            Write-Err "Failed to back up: $f  ($_)"
            Write-Log "Failed to back up ${f}: $_" -Level "ERROR"
            $failed++
        }
    }

    # Summary
    Write-Host ""
    if ($failed -gt 0) {
        Write-Warn "Backup completed with errors: $copied file(s) copied, $failed failed."
        Write-Log "Backup finished with errors: $copied OK, $failed failed." -Level "WARN"
    } else {
        Write-Success "Backup complete! $copied file(s) successfully backed up."
        Write-Log "Backup complete: $copied file(s) backed up to $destFolder" -Level "OK"
    }

    # Prune old backups - keep MaxBackupVersions newest
    Invoke-PruneOldBackups -Config $Config

    Write-Log "--- Backup process finished ---"
}

function Invoke-PruneOldBackups {
    param([hashtable]$Config)

    $max = [int]$Config.MaxBackupVersions
    $all = @(Get-BackupList -Config $Config)

    if ($all.Count -le $max) { return }

    # Already sorted newest-first; remove the oldest ones
    $toDelete = @($all | Select-Object -Skip $max)

    Write-Host ""
    Write-Info "Maintaining max $max backup versions. Removing $($toDelete.Count) oldest..."
    Write-Log "Pruning $($toDelete.Count) old backup(s) to maintain limit of $max."

    foreach ($old in $toDelete) {
        try {
            Remove-Item -LiteralPath $old.FullPath -Recurse -Force
            Write-Detail "Removed old backup: $($old.FolderName)"
            Write-Log "Removed old backup: $($old.FolderName)" -Level "INFO"
        } catch {
            Write-Warn "Could not remove old backup '$($old.FolderName)': $_"
            Write-Log "Failed to remove old backup '$($old.FolderName)': $_" -Level "WARN"
        }
    }
}

# ============================================================
#  REGION: Restore Process
# ============================================================

function Invoke-Restore {
    param([hashtable]$Config)

    Write-Section "Restore Process"
    Write-Log "--- Restore process started ---"

    $backups = @(Get-BackupList -Config $Config)

    if ($backups.Count -eq 0) {
        Write-Err "No backups found in: $BackupRoot"
        Write-Warn "Please run a backup first before attempting a restore."
        Write-Log "Restore aborted - no backups found." -Level "ERROR"
        return
    }

    # List available backups
    Write-Info "Available backup versions:"
    Write-Host ""
    Write-Host ("  {0,-4} {1,-20} {2}" -f "#", "Date / Time", "Files") -ForegroundColor DarkCyan
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $backups.Count; $i++) {
        $b        = $backups[$i]
        $dtStr    = $b.DateTime.ToString("dd.MM.yyyy  HH:mm")
        $fileList = (@($b.Files)) -join ", "
        Write-Host ("  {0,-4} {1,-20} {2}" -f ($i + 1), $dtStr, $fileList) -ForegroundColor White
    }

    Write-Host ""

    # Ask user which backup to restore
    $chosen = $null
    while ($null -eq $chosen) {
        Write-Host "  Enter backup number to restore (or 0 to cancel): " -NoNewline -ForegroundColor White
        $raw = Read-Host
        if ($raw -match '^\d+$') {
            $num = [int]$raw
            if ($num -eq 0) {
                Write-Info "Restore cancelled by user."
                Write-Log "Restore cancelled by user."
                return
            }
            if ($num -ge 1 -and $num -le $backups.Count) {
                $chosen = $backups[$num - 1]
            } else {
                Write-Warn "Invalid selection. Please enter a number between 1 and $($backups.Count)."
            }
        } else {
            Write-Warn "Invalid input. Please enter a number."
        }
    }

    $dest = $Config.SourceFolder

    Write-Host ""
    Write-Warn "============================================================"
    Write-Warn "  WARNING: You are about to restore the following backup:"
    Write-Host ""
    Write-Host ("   Backup  : " + $chosen.FolderName) -ForegroundColor White
    Write-Host ("   Files   : " + (@($chosen.Files) -join ", ")) -ForegroundColor White
    Write-Host ("   To      : " + $dest) -ForegroundColor White
    Write-Host ""
    Write-Warn "  Any existing files at the destination WILL BE OVERWRITTEN."
    Write-Warn "  This action CANNOT BE UNDONE."
    Write-Warn "============================================================"
    Write-Host ""

    if (-not (Read-YesNo -Prompt "Are you sure you want to restore this backup?" -Default "N")) {
        Write-Info "Restore cancelled by user."
        Write-Log "Restore cancelled by user at confirmation." -Level "INFO"
        return
    }

    # Ensure destination folder exists
    if (-not (Test-Path $dest)) {
        Write-Warn "Destination folder does not exist. Attempting to create it..."
        try {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Write-Success "Created destination folder: $dest"
            Write-Log "Created destination folder: $dest" -Level "OK"
        } catch {
            Write-Err "Could not create destination folder: $_"
            Write-Log "Failed to create destination folder: $_" -Level "ERROR"
            return
        }
    }

    # Restore files
    $restored = 0
    $failed   = 0

    foreach ($f in @($chosen.Files)) {
        $srcFile  = Join-Path $chosen.FullPath $f
        $destFile = Join-Path $dest $f

        Write-Info "Restoring: $f ..."

        # Handle read-only attribute gracefully
        if (Test-Path $destFile) {
            try {
                $attrs = (Get-Item $destFile -Force).Attributes
                if ($attrs -band [System.IO.FileAttributes]::ReadOnly) {
                    Write-Detail "File is read-only. Removing read-only attribute..."
                    Set-ItemProperty -LiteralPath $destFile -Name Attributes -Value ($attrs -bxor [System.IO.FileAttributes]::ReadOnly)
                    Write-Log "Removed read-only attribute from: $destFile" -Level "INFO"
                }
            } catch {
                Write-Warn "Could not clear read-only attribute on '$f': $_"
                Write-Log "Could not clear read-only on ${destFile}: $_" -Level "WARN"
            }
        }

        try {
            Copy-Item -LiteralPath $srcFile -Destination $destFile -Force
            $size = (Get-Item $destFile).Length
            Write-Success "Restored: $f  ($size bytes)"
            Write-Log "Restored: $f -> $destFile  ($size bytes)" -Level "OK"
            $restored++
        } catch {
            Write-Err "Failed to restore: $f  ($_)"
            Write-Log "Failed to restore ${f}: $_" -Level "ERROR"
            $failed++
        }
    }

    # Final result
    Write-Host ""
    if ($failed -eq 0 -and $restored -gt 0) {
        Write-Success "Restore completed successfully! $restored file(s) restored."
        Write-Success "Destination: $dest"
        Write-Log "Restore complete: $restored file(s) restored from $($chosen.FolderName)" -Level "OK"
    } elseif ($restored -gt 0 -and $failed -gt 0) {
        Write-Warn "Restore completed with errors: $restored file(s) OK, $failed failed."
        Write-Warn "Check the log for details: $LogFile"
        Write-Log "Restore finished with errors: $restored OK, $failed failed." -Level "WARN"
    } else {
        Write-Err "Restore failed. No files were restored."
        Write-Err "Check the log for details: $LogFile"
        Write-Log "Restore failed completely." -Level "ERROR"
    }

    Write-Log "--- Restore process finished ---"
}

# ============================================================
#  REGION: Main Entry Point
# ============================================================

function Main {
    # Initialize log
    Write-LogDivider
    Write-Log "Script started: $SCRIPT_TITLE v$SCRIPT_VERSION"
    Write-Log "Script root   : $ScriptRoot"
    Write-Log "PowerShell    : $($PSVersionTable.PSVersion)"
    Write-Log "OS            : $([System.Environment]::OSVersion.VersionString)"
    Write-Log "User          : $([System.Environment]::UserName)"
    Write-Log "Elevated      : $(if (Test-IsAdmin) { 'Yes' } else { 'No' })"

    # Display header
    Clear-Host
    Write-Header $SCRIPT_TITLE

    $elevatedStatus = if (Test-IsAdmin) { "Yes" } else { "NO - some operations may fail!" }
    $elevatedColor  = if (Test-IsAdmin) { "DarkGray" } else { "Yellow" }

    Write-Host "  Version   : $SCRIPT_VERSION" -ForegroundColor DarkGray
    Write-Host "  Script dir: $ScriptRoot" -ForegroundColor DarkGray
    Write-Host "  Log file  : $LogFile" -ForegroundColor DarkGray
    Write-Host "  Config    : $ConfigFile" -ForegroundColor DarkGray
    Write-Host "  Elevated  : $elevatedStatus" -ForegroundColor $elevatedColor
    Write-Host ""

    # Load config
    $Config = Load-Config

    # Ensure config values are mutable hashtable (handles ConvertFrom-Json PSCustomObject)
    if ($Config -isnot [hashtable] -and $Config -isnot [System.Collections.Specialized.OrderedDictionary]) {
        $ht = [ordered]@{}
        $Config.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        $Config = $ht
    }

    # Normalize FilesToBackup to string array (JSON parse can return arrays)
    $ftb = $Config["FilesToBackup"]
    if ($ftb -isnot [array]) { $Config["FilesToBackup"] = @($ftb) }

    # Show current backup status
    $backups = @(Get-BackupList -Config $Config)
    Show-BackupStatus -Backups $backups -Config $Config

    # Main menu loop
    $running = $true
    while ($running) {
        Write-Section "Main Menu"
        Write-Host "  What would you like to do?" -ForegroundColor White
        Write-Host ""
        Write-Host "   [1] Create Backup" -ForegroundColor Cyan
        Write-Host "   [2] Restore from Backup" -ForegroundColor Cyan
        Write-Host "   [3] Show Backup Status" -ForegroundColor Cyan
        Write-Host "   [0] Exit" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Your choice: " -NoNewline -ForegroundColor White

        $choice = Read-Host

        switch ($choice.Trim()) {
            "1" {
                Invoke-Backup -Config $Config
                $backups = @(Get-BackupList -Config $Config)   # refresh
                Pause-ForUser
            }
            "2" {
                Invoke-Restore -Config $Config
                Pause-ForUser
            }
            "3" {
                $backups = @(Get-BackupList -Config $Config)
                Show-BackupStatus -Backups $backups -Config $Config
                Pause-ForUser
            }
            "0" {
                $running = $false
            }
            default {
                Write-Warn "Invalid option. Please enter 1, 2, 3, or 0."
            }
        }
    }

    Write-Host ""
    Write-Success "Thank you for using $SCRIPT_TITLE."
    Write-Info "Log saved to: $LogFile"
    Write-Host ""
    Write-Log "Script exited normally."
    Write-LogDivider
}

# ============================================================
#  ENTRY
# ============================================================

try {
    Main
    exit 0
} catch {
    $errMsg = $_.ToString()
    Write-Host ""
    Write-Host "  [FATAL] An unexpected error occurred:" -ForegroundColor Red
    Write-Host "  $errMsg" -ForegroundColor Red
    Write-Host ""
    try { Write-Log "FATAL ERROR: $errMsg" -Level "ERROR" } catch {}
    exit 1
}
