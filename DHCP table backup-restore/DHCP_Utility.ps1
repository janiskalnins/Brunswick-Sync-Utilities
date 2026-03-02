# ==============================================================
#  DHCP_Utility.ps1
#  Consolidated DHCP Backup, Restore, Delete and Service Utility
#  Version  : 5.0
#  Requires : PowerShell 3.0+  (Windows Server 2012 / Win 8+)
#  Encoding : UTF-8 without BOM
#
#  v5.0 additions:
#    - Invoke-DeleteScope  : probe live DHCP server for scopes,
#      let user select and delete individual scopes or all at once.
#      Uses DhcpServer PS module when available (WS2012 R2+),
#      falls back to netsh parsing for plain WS2012 / PS 3.0.
#    - Invoke-ServiceManager : interactive Start / Stop / Restart
#      of the DHCP Server service with live status display.
#    - Invoke-Restore now offers automatic scope pre-deletion
#      before import (required for a fully clean restore).
# ==============================================================
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Backup','Restore','Delete','DeleteScope','ServiceManager','Menu')]
    [string]$Mode = 'Menu'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ==============================================================
#  GLOBAL TRAP
#  Catches any unhandled terminating error, prints it in red,
#  then pauses so the user can read it before the window closes.
# ==============================================================
trap {
    Write-Host ''
    Write-Host '  !! UNHANDLED ERROR !!' -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    Write-Host ''
    try { Add-Content -Path $LogFile -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] TRAP: $_" -Encoding ASCII } catch {}
    Read-Host '  Press Enter to return to menu'
    continue
}


# ==============================================================
#  PATHS
#  $PSScriptRoot is set by PowerShell when the script is run
#  with -File.  Add a fallback for edge cases where it is empty
#  (dot-source, ISE, some older PS3 invocations).
# ==============================================================
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $ScriptDir = $PSScriptRoot
}
else {
    # Fallback 1: use the path of the script itself
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $ScriptDir -or $ScriptDir -eq '') {
    # Fallback 2: use current working directory
    $ScriptDir = (Get-Location).Path
}

$BackupsRoot = Join-Path $ScriptDir 'Backups'
$LogFile     = Join-Path $ScriptDir 'dhcp_utility.log'
$ConfigFile  = Join-Path $ScriptDir 'dhcp_config.json'
# TempExport goes to the local TEMP folder, never to the USB drive.
# netsh cannot reliably write to a network share or USB path.
$TempExport  = Join-Path $env:TEMP 'dhcp_export_temp.txt'


# ==============================================================
#  HELPER : Write-Log
#  Plain ASCII timestamped append.
# ==============================================================
function Write-Log {
    param([string]$Message)
    # Ensure the log folder exists before the first write
    $logDir = Split-Path $LogFile -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] $Message" -Encoding ASCII
}


# ==============================================================
#  HELPER : Out-Header
# ==============================================================
function Out-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host "    $Title" -ForegroundColor Cyan
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host ''
}


# ==============================================================
#  HELPER : Out-Banner  (single coloured status line)
# ==============================================================
function Out-Banner {
    param([string]$Text, [string]$Color = 'White')
    Write-Host "  $Text" -ForegroundColor $Color
}


# ==============================================================
#  HELPER : Get-SHA256
#  Uses Get-FileHash (PS 4.0+) or .NET fallback for PS 3.0.
# ==============================================================
function Get-SHA256 {
    param([string]$FilePath)
    if (Get-Command -Name Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToUpper()
    }
    # PS 3.0 fallback (.NET)
    $sha    = [System.Security.Cryptography.SHA256Managed]::Create()
    $stream = [System.IO.File]::OpenRead($FilePath)
    try   { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-','').ToUpper() }
    finally { $stream.Close(); $sha.Dispose() }
}


# ==============================================================
#  HELPER : Save-HashSidecar
#  Writes a .sha256 JSON file alongside a backup set.
# ==============================================================
function Save-HashSidecar {
    param(
        [string]$SidecarPath,
        [string]$Server,
        [string]$Timestamp,
        [string]$TxtHash,
        [string]$BakHash
    )
    $json = "{`r`n" +
            "  `"server`":    `"$Server`",`r`n" +
            "  `"timestamp`": `"$Timestamp`",`r`n" +
            "  `"created`":   `"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`",`r`n" +
            "  `"txt_hash`":  `"$TxtHash`",`r`n" +
            "  `"bak_hash`":  `"$BakHash`"`r`n" +
            "}"
    # Write with ASCII encoding - no BOM, no multi-byte characters
    [System.IO.File]::WriteAllText($SidecarPath, $json,
        [System.Text.Encoding]::ASCII)
    Write-Log "Hash sidecar saved : $SidecarPath"
    Write-Log "  txt_hash : $TxtHash"
    Write-Log "  bak_hash : $BakHash"
}


# ==============================================================
#  HELPER : Test-HashSidecar
#  Reads the .sha256 sidecar for a .txt file, re-hashes the
#  live file, and compares.
#  Returns hashtable with .Ok (bool) and .Reason (string).
# ==============================================================
function Test-HashSidecar {
    param([string]$TxtPath)

    $base    = [System.IO.Path]::GetFileNameWithoutExtension($TxtPath)
    $dir     = [System.IO.Path]::GetDirectoryName($TxtPath)
    $sidecar = Join-Path $dir "$base.sha256"

    if (-not (Test-Path $sidecar)) {
        return @{ Ok = $false; Reason = "Hash sidecar not found: ${sidecar}" }
    }

    # Read with explicit ASCII to avoid BOM surprises
    try {
        $raw    = [System.IO.File]::ReadAllText($sidecar, [System.Text.Encoding]::ASCII)
        $stored = $raw | ConvertFrom-Json
    }
    catch {
        return @{ Ok = $false; Reason = "Could not parse sidecar: $_" }
    }

    if (-not $stored -or -not $stored.txt_hash) {
        return @{ Ok = $false; Reason = 'Sidecar missing txt_hash field.' }
    }

    $liveHash = Get-SHA256 $TxtPath

    if ($liveHash -ne $stored.txt_hash.ToUpper()) {
        return @{
            Ok     = $false
            Reason = "MISMATCH  Stored=$($stored.txt_hash)  Live=$liveHash"
        }
    }

    return @{
        Ok         = $true
        Reason     = 'OK'
        StoredHash = $stored.txt_hash
        LiveHash   = $liveHash
        Sidecar    = $sidecar
    }
}


# ==============================================================
#  HELPER : Get-SafeName
#  Replaces illegal folder-name characters with underscores.
# ==============================================================
function Get-SafeName {
    param([string]$Name)
    $safe = $Name -replace '[/\\:*?"<>|= ]', '_'
    $safe = $safe -replace '_+', '_'
    $safe = $safe.Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'DHCP_Server' }
    return $safe
}


# ==============================================================
#  HELPER : Write-OSVersion
# ==============================================================
function Write-OSVersion {
    try {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        Write-Log "OS Caption : $($os.Caption.Trim())"
        Write-Log "OS Version : $($os.Version)"
        Write-Log "OS Build   : $($os.BuildNumber)"
    }
    catch { Write-Log "OS info    : WMI error - $($_.Exception.Message)" }
    Write-Log "PS Version : $($PSVersionTable.PSVersion)"
    Write-Log "ScriptDir  : ${ScriptDir}"
}


# ==============================================================
#  HELPER : Initialize-Config
# ==============================================================
function Initialize-Config {
    if (-not (Test-Path $ConfigFile)) {
        $json = "{`r`n" +
                "  `"script_version`": `"4.1`",`r`n" +
                "  `"backups_root`":   `"Backups`",`r`n" +
                "  `"last_backup`":    {},`r`n" +
                "  `"last_restore`":   {}`r`n" +
                "}"
        [System.IO.File]::WriteAllText($ConfigFile, $json,
            [System.Text.Encoding]::ASCII)
        Write-Log "Config created: ${ConfigFile}"
    }
}


# ==============================================================
#  HELPER : Save-Config  (generic - writes pre-built JSON string)
# ==============================================================
function Save-BackupConfig {
    param(
        [string]$Server,
        [string]$RelativeFile,
        [string]$Timestamp,
        [string]$IntegrityOk,
        [string]$TxtHash,
        [string]$BakHash
    )
    $json = "{`r`n" +
            "  `"script_version`": `"4.1`",`r`n" +
            "  `"backups_root`":   `"Backups`",`r`n" +
            "  `"last_backup`": {`r`n" +
            "    `"server`":       `"$Server`",`r`n" +
            "    `"file`":         `"$($RelativeFile -replace '\\','/')`",`r`n" +
            "    `"timestamp`":    `"$Timestamp`",`r`n" +
            "    `"integrity_ok`": $IntegrityOk,`r`n" +
            "    `"txt_hash`":     `"$TxtHash`",`r`n" +
            "    `"bak_hash`":     `"$BakHash`"`r`n" +
            "  },`r`n" +
            "  `"last_restore`": {}`r`n" +
            "}"
    [System.IO.File]::WriteAllText($ConfigFile, $json,
        [System.Text.Encoding]::ASCII)
    Write-Log "Config updated: last_backup = $Server @ $Timestamp"
}

function Save-RestoreConfig {
    param([string]$Location, [string]$FileName, [string]$RelativePath)
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $json = "{`r`n" +
            "  `"script_version`": `"4.1`",`r`n" +
            "  `"backups_root`":   `"Backups`",`r`n" +
            "  `"last_backup`": {},`r`n" +
            "  `"last_restore`": {`r`n" +
            "    `"location`":      `"$Location`",`r`n" +
            "    `"file`":          `"$FileName`",`r`n" +
            "    `"relative_path`": `"$($RelativePath -replace '\\','/')`",`r`n" +
            "    `"timestamp`":     `"$ts`"`r`n" +
            "  }`r`n" +
            "}"
    [System.IO.File]::WriteAllText($ConfigFile, $json,
        [System.Text.Encoding]::ASCII)
    Write-Log "Config updated: last_restore = $Location / $FileName"
}


# ==============================================================
#  HELPER : Read-NonEmptyInput
#  Returns the trimmed string the user typed.
#  Returns $null if the user types 0 or leaves the line blank -
#  both are treated as cancel.  Callers must check for $null.
# ==============================================================
function Read-NonEmptyInput {
    param([string]$Prompt)
    while ($true) {
        $v = (Read-Host "$Prompt  (0=Cancel)").Trim()
        if ($v -eq '0' -or $v -eq '') { return $null }
        if (-not [string]::IsNullOrWhiteSpace($v))  { return $v  }
        Out-Banner '[!] Input cannot be blank. Enter 0 to cancel.' Yellow
    }
}


# ==============================================================
#  HELPER : Select-FromList
#  Prompts until the user enters a valid 1-based number.
#  Returns 0-based index of the selection.
#  Returns -1 when the user enters 0 (cancel signal).
#  Every caller must:  if ($result -eq -1) { <cancel path> }
# ==============================================================
function Select-FromList {
    param([string]$Prompt, [int]$Count)
    while ($true) {
        $raw   = (Read-Host "$Prompt  (0=Cancel)").Trim()
        $num   = 0
        $isNum = [int]::TryParse($raw, [ref]$num)
        if ($isNum -and $num -eq 0)                       { return -1 }
        if ($isNum -and $num -ge 1 -and $num -le $Count)  { return ($num - 1) }
        Out-Banner "[!] Enter a number between 1 and $Count, or 0 to cancel." Yellow
    }
}


# ==============================================================
#  HELPER : Test-DhcpService
#  Returns $true if the DHCP Server service exists on this box.
#  Uses Get-Service (pure PS) -- avoids sc.exe $LASTEXITCODE
#  unreliability when called from within PowerShell.
# ==============================================================
function Test-DhcpService {
    $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    return ($null -ne $svc)
}


# ==============================================================
#  HELPER : Get-DhcpScopes
#  Returns an array of scope objects from the local DHCP server.
#  Each object has: Version, ScopeId, Mask, State, Name.
#
#  Strategy (broad compatibility):
#    1. Try the DhcpServer PowerShell module (WS2012 R2+ / PS4+).
#       The module is only present when the DHCP role is installed.
#    2. Fall back to parsing  netsh dhcp server show scope  output,
#       which works on plain WS2012 with PS 3.0.
# ==============================================================
function Get-DhcpScopes {
    $scopes = @()

    # -- Attempt 1: DhcpServer module (preferred) --
    $modAvail = Get-Module -ListAvailable -Name DhcpServer -ErrorAction SilentlyContinue
    if ($modAvail) {
        try {
            Import-Module DhcpServer -ErrorAction Stop | Out-Null
            $v4 = @(Get-DhcpServerv4Scope -ErrorAction Stop)
            foreach ($s in $v4) {
                $scopes += [PSCustomObject]@{
                    Version = 'IPv4'
                    ScopeId = $s.ScopeId.ToString()
                    Mask    = $s.SubnetMask.ToString()
                    State   = $s.State.ToString()
                    Name    = if ($s.Name) { $s.Name } else { '(no name)' }
                }
            }
            try {
                $v6 = @(Get-DhcpServerv6Scope -ErrorAction Stop)
                foreach ($s in $v6) {
                    $scopes += [PSCustomObject]@{
                        Version = 'IPv6'
                        ScopeId = $s.Prefix.ToString()
                        Mask    = "/$($s.Prefix.PrefixLength)"
                        State   = $s.State.ToString()
                        Name    = if ($s.Name) { $s.Name } else { '(no name)' }
                    }
                }
            }
            catch { <# IPv6 may not exist - silently skip #> }

            Write-Log "Get-DhcpScopes: found $($scopes.Count) scope(s) via DhcpServer module."
            return $scopes
        }
        catch {
            Write-Log "Get-DhcpScopes: DhcpServer module failed ($($_)), falling back to netsh."
        }
    }

    # -- Attempt 2: netsh fallback --
    Write-Log 'Get-DhcpScopes: using netsh fallback.'
    $netshOut = & netsh dhcp server show scope 2>&1
    Write-Log "netsh show scope output: $($netshOut -join ' | ')"

    foreach ($line in $netshOut) {
        # Typical line: "192.168.1.0     - 255.255.255.0  -Active   -Office LAN   -"
        if ($line -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*-\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*-\s*(\S+)\s*-([^-]*)-?') {
            $scopes += [PSCustomObject]@{
                Version = 'IPv4'
                ScopeId = $Matches[1].Trim()
                Mask    = $Matches[2].Trim()
                State   = $Matches[3].Trim()
                Name    = $Matches[4].Trim()
            }
        }
    }

    Write-Log "Get-DhcpScopes: found $($scopes.Count) scope(s) via netsh."
    return $scopes
}


# ==============================================================
#  HELPER : Remove-DhcpScope
#  Deletes a single scope by ScopeId (IP for v4, prefix for v6).
#  Returns $true on success, $false on failure.
#  Uses DhcpServer module when available, falls back to netsh.
# ==============================================================
function Remove-DhcpScope {
    param(
        [string]$ScopeId,
        [string]$Version = 'IPv4'
    )

    $modAvail = Get-Module -Name DhcpServer -ErrorAction SilentlyContinue
    if (-not $modAvail) {
        $modAvail = Get-Module -ListAvailable -Name DhcpServer -ErrorAction SilentlyContinue
        if ($modAvail) { Import-Module DhcpServer -ErrorAction SilentlyContinue | Out-Null }
    }

    if ($modAvail) {
        try {
            if ($Version -eq 'IPv6') {
                Remove-DhcpServerv6Scope -Prefix $ScopeId -Force -ErrorAction Stop
            }
            else {
                Remove-DhcpServerv4Scope -ScopeId $ScopeId -Force -ErrorAction Stop
            }
            Write-Log "Removed scope ${ScopeId} via DhcpServer module."
            return $true
        }
        catch {
            Write-Log "Module remove failed for ${ScopeId}: $_.  Trying netsh."
        }
    }

    # netsh fallback (IPv4 only)
    $out  = & netsh dhcp server scope $ScopeId delete 2>&1
    $code = $LASTEXITCODE
    Write-Log "netsh scope ${ScopeId} delete: exit=$code  out=$($out -join ' | ')"
    return ($code -eq 0)
}


# ==============================================================
#  BACKUP
# ==============================================================
function Invoke-Backup {

    Out-Header 'DHCP TABLE BACKUP  v4.1'
    Write-Host "  Script dir  : ${ScriptDir}"
    Write-Host "  Backups root: ${BackupsRoot}"
    Write-Host "  Log file    : ${LogFile}"
    Write-Host "  Temp path   : ${TempExport}"
    Write-Host ''

    Write-Log '=================================================='
    Write-Log 'Backup session start'
    Write-Log "Script dir   : ${ScriptDir}"
    Write-Log "Backups root : ${BackupsRoot}"
    Write-Log "Temp path    : ${TempExport}"
    Write-OSVersion
    Write-Log '=================================================='

    if (-not (Test-Path $BackupsRoot)) {
        New-Item -ItemType Directory -Path $BackupsRoot -Force | Out-Null
        Write-Log "Created Backups root: ${BackupsRoot}"
        Out-Banner '[+] Created Backups root folder.' Green
    }

    Initialize-Config

    # Pre-flight: DHCP Server role present?
    Out-Banner '[*] Checking DHCP Server service...' Cyan
    if (-not (Test-DhcpService)) {
        Write-Host ''
        Out-Banner '[X] ERROR: DHCP Server service not found on this machine.' Red
        Out-Banner '    The DHCP Server role must be installed before running a backup.' Red
        Write-Log 'ERROR: DHCPServer service not found. Backup aborted.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    Out-Banner '[+] DHCP Server service found.' Green
    Write-Log 'DHCP Server service confirmed.'
    Write-Host ''

    # -- Show existing backup locations, let user pick one or create new --
    $existingLocs = @(Get-ChildItem $BackupsRoot -Directory -ErrorAction SilentlyContinue)

    $serverName = ''
    $safeName   = ''

    if ($existingLocs.Count -gt 0) {
        Write-Host '  Existing backup locations:'
        Write-Host '  --------------------------------------------------'
        Write-Host ''
        for ($li = 0; $li -lt $existingLocs.Count; $li++) {
            $loc    = $existingLocs[$li]
            $cnt    = @(Get-ChildItem $loc.FullName -Filter '*.txt' -ErrorAction SilentlyContinue).Count
            $latest = Get-ChildItem $loc.FullName -Filter '*.txt' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $latestStr = if ($latest) { $latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { 'none' }
            Write-Host "    [$($li+1)]  $($loc.Name.PadRight(24))  $cnt backup(s)   latest: $latestStr"
        }
        $newIdx = $existingLocs.Count + 1
        Write-Host "    [$newIdx]  (Create a new location)"
        Write-Host ''

        $locChoice = Select-FromList '  Select location number' $newIdx

        if ($locChoice -eq -1) {
            Out-Banner '[i] Backup cancelled.' Cyan
            Write-Log 'Backup: cancelled at location selection.'
            Write-Host ''
            Read-Host '  Press Enter to return to menu'
            return
        }

        if ($locChoice -lt $existingLocs.Count) {
            # User picked an existing location
            $chosenFolder = $existingLocs[$locChoice]
            $safeName     = $chosenFolder.Name
            $serverName   = $safeName          # display name = folder name for existing locations
            Write-Host ''
            Out-Banner "[i] Adding backup to existing location: $safeName" Cyan
            Write-Log "Backup location: existing folder '$safeName' selected by user."
        }
        else {
            # User wants a new location -- fall through to name prompt below
            Write-Host ''
            Write-Host '  Enter the name for the new Server / Location.'
            Write-Host '  Examples:  DC01   HQ-DHCP   Branch-London   SiteA'
            Write-Host ''

            do {
                $serverName = Read-NonEmptyInput '  New Server / Location name'
                if ($null -eq $serverName) {
                    Out-Banner '[i] Backup cancelled.' Cyan
                    Write-Log 'Backup: cancelled at new location name entry.'
                    Write-Host ''
                    Read-Host '  Press Enter to return to menu'
                    return
                }
                $safeName   = Get-SafeName $serverName
                Write-Host ''
                Out-Banner "[i] Backup folder will be named: $safeName" Cyan
                # Warn if name collides with an existing folder despite going through 'new'
                if (Test-Path (Join-Path $BackupsRoot $safeName)) {
                    Out-Banner "[!] A folder named '$safeName' already exists. Backups will be added to it." Yellow
                }
                Write-Host ''
                $ok = (Read-Host '  Is this correct? [Y/N]') -match '^[Yy]$'
                if (-not $ok) { Write-Host '' }
            } while (-not $ok)

            Write-Log "Backup location: new folder '$safeName' (entered as '$serverName')."
        }
    }
    else {
        # No existing locations at all -- go straight to name prompt
        Write-Host '  No existing backup locations found. Enter a name for this Server / Location.'
        Write-Host '  Examples:  DC01   HQ-DHCP   Branch-London   SiteA'
        Write-Host ''

        do {
            $serverName = Read-NonEmptyInput '  Server / Location name'
            if ($null -eq $serverName) {
                Out-Banner '[i] Backup cancelled.' Cyan
                Write-Log 'Backup: cancelled at location name entry.'
                Write-Host ''
                Read-Host '  Press Enter to return to menu'
                return
            }
            $safeName   = Get-SafeName $serverName
            Write-Host ''
            Out-Banner "[i] Backup folder will be named: $safeName" Cyan
            Write-Host ''
            $ok = (Read-Host '  Is this correct? [Y/N]') -match '^[Yy]$'
            if (-not $ok) { Write-Host '' }
        } while (-not $ok)

        Write-Log "Backup location: new folder '$safeName' (first backup, entered as '$serverName')."
    }

    Write-Host ''
    Write-Log "Server/Location : $serverName  (folder: $safeName)"

    # Build all file paths for this session
    $timestamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
    $baseName      = "dhcp_${safeName}_${timestamp}"
    $backupFolder  = Join-Path $BackupsRoot $safeName
    $backupFile    = Join-Path $backupFolder "$baseName.txt"
    $backupCopy    = Join-Path $backupFolder "$baseName.bak"
    $hashSidecar   = Join-Path $backupFolder "$baseName.sha256"
    $relFile       = "Backups\$safeName\$baseName.txt"
    $relSidecar    = "Backups\$safeName\$baseName.sha256"

    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host '   Backup Details' -ForegroundColor Cyan
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host "   Server / Location : $serverName"
    Write-Host "   Folder            : ${backupFolder}"
    Write-Host "   Primary file      : $baseName.txt"
    Write-Host "   Redundant copy    : $baseName.bak"
    Write-Host "   Hash sidecar      : $baseName.sha256"
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host ''

    Write-Log "Backup folder  : ${backupFolder}"
    Write-Log "Primary file   : ${backupFile}"
    Write-Log "Backup copy    : ${backupCopy}"
    Write-Log "Hash sidecar   : ${hashSidecar}"

    if (-not (Test-Path $backupFolder)) {
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        Write-Log "Created folder: ${backupFolder}"
        Out-Banner '[+] Created Server/Location folder.' Green
    }
    else {
        Write-Log "Folder exists: ${backupFolder}"
        Out-Banner '[i] Adding to existing folder.' Cyan
    }

    Write-Host ''
    Out-Banner '[*] Exporting DHCP table - please wait...' Cyan

    if (Test-Path $TempExport) { Remove-Item $TempExport -Force }

    Write-Log "Running: netsh dhcp server export ${TempExport} all"

    # Run netsh and capture output; check exit code after
    $netshOut  = & netsh dhcp server export $TempExport all 2>&1
    $netshExit = $LASTEXITCODE

    Write-Log "netsh exit   : $netshExit"
    Write-Log "netsh output : $($netshOut -join ' | ')"

    if ($netshExit -ne 0) {
        Write-Host ''
        Out-Banner "[X] ERROR: netsh export command failed (exit code: $netshExit)." Red
        Out-Banner "    Output: $($netshOut -join ' ')" Yellow
        Write-Log "ERROR: netsh non-zero exit: $netshExit"
        Write-Log '--- Backup FAILED ---'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    if (-not (Test-Path $TempExport)) {
        Write-Host ''
        Out-Banner '[X] ERROR: netsh returned success but no export file was created.' Red
        Out-Banner '    The DHCP service may be stopped or no scopes are configured.' Yellow
        Out-Banner '    1. Open services.msc and confirm DHCP Server is Running.' Yellow
        Out-Banner '    2. Confirm scopes exist in the DHCP console.' Yellow
        Out-Banner '    3. Run backup again.' Yellow
        Write-Log 'ERROR: netsh exit 0 but no export file found at temp path.'
        Write-Log '--- Backup FAILED ---'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    $exportSize = (Get-Item $TempExport).Length
    Out-Banner "[+] DHCP table exported successfully. ($exportSize bytes)" Green
    Write-Log "Export OK. Size: $exportSize bytes"

    # Copy to primary and redundant copy
    Out-Banner '[*] Saving primary backup file...' Cyan
    try {
        Copy-Item $TempExport $backupFile -Force -ErrorAction Stop
        Out-Banner '[+] Primary file saved.' Green
        Write-Log "Primary saved: ${backupFile}"
    }
    catch {
        Out-Banner "[X] ERROR saving primary file: $_" Red
        Write-Log "ERROR: Primary copy failed: $_"
        Write-Log '--- Backup FAILED ---'
        Read-Host '  Press Enter to return to menu'
        return
    }

    Out-Banner '[*] Creating redundant backup copy (.bak)...' Cyan
    try {
        Copy-Item $TempExport $backupCopy -Force -ErrorAction Stop
        Out-Banner '[+] Redundant copy saved.' Green
        Write-Log "Backup copy saved: ${backupCopy}"
    }
    catch {
        Out-Banner "[X] ERROR saving backup copy: $_" Red
        Write-Log "ERROR: Backup copy failed: $_"
        Write-Log '--- Backup FAILED ---'
        Read-Host '  Press Enter to return to menu'
        return
    }

    # SHA-256 integrity check
    Write-Host ''
    Out-Banner '[*] Computing SHA-256 hashes...' Cyan
    Write-Host ''

    $hashSrc  = Get-SHA256 $TempExport
    $hashPrim = Get-SHA256 $backupFile
    $hashCopy = Get-SHA256 $backupCopy

    Write-Host "   Source (temp) : $hashSrc"
    Write-Host "   Primary .txt  : $hashPrim"
    Write-Host "   Copy .bak     : $hashCopy"
    Write-Host ''

    $integrityOk = $true
    if ($hashSrc -ne $hashPrim) {
        Out-Banner '[X] WARNING: Primary hash does NOT match source!' Red
        Write-Log 'WARNING: Hash mismatch - source vs primary.'
        $integrityOk = $false
    }
    if ($hashSrc -ne $hashCopy) {
        Out-Banner '[X] WARNING: Copy hash does NOT match source!' Red
        Write-Log 'WARNING: Hash mismatch - source vs copy.'
        $integrityOk = $false
    }

    if ($integrityOk) {
        Out-Banner '[+] Integrity check PASSED - all three files match.' Green
        Write-Log 'Integrity check PASSED.'
    }
    else {
        Out-Banner '[!] INTEGRITY CHECK FAILED - files may be corrupted!' Red
        Write-Log 'ERROR: Integrity check FAILED.'
    }

    # Save hash sidecar
    Out-Banner '[*] Saving hash sidecar (.sha256)...' Cyan
    try {
        Save-HashSidecar -SidecarPath $hashSidecar `
                         -Server      $serverName  `
                         -Timestamp   $timestamp   `
                         -TxtHash     $hashPrim    `
                         -BakHash     $hashCopy
        Out-Banner '[+] Hash sidecar saved.' Green
    }
    catch {
        Out-Banner "[!] WARNING: Could not save hash sidecar: $_" Yellow
        Write-Log "WARNING: Sidecar save failed: $_"
    }

    # Update config and clean up
    $intStr = if ($integrityOk) { 'true' } else { 'false' }
    Save-BackupConfig -Server       $serverName `
                      -RelativeFile $relFile    `
                      -Timestamp    $timestamp  `
                      -IntegrityOk  $intStr     `
                      -TxtHash      $hashPrim   `
                      -BakHash      $hashCopy

    Remove-Item $TempExport -Force -ErrorAction SilentlyContinue
    Write-Log 'Temp export removed.'

    Write-Host ''
    if ($integrityOk) {
        Write-Host '  ==================================================' -ForegroundColor Green
        Write-Host '    BACKUP COMPLETED SUCCESSFULLY' -ForegroundColor Green
        Write-Host '  ==================================================' -ForegroundColor Green
    }
    else {
        Write-Host '  ==================================================' -ForegroundColor Yellow
        Write-Host '    BACKUP COMPLETED WITH WARNINGS  (check log)' -ForegroundColor Yellow
        Write-Host '  ==================================================' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host "   Server / Location : $serverName"
    Write-Host "   Primary file      : $relFile"
    Write-Host "   Hash sidecar      : $relSidecar"
    Write-Host "   Log               : ${LogFile}"
    Write-Host ''
    Write-Log "--- Backup COMPLETED for: $serverName ---"
    Write-Log '=================================================='

    Read-Host '  Press Enter to return to menu'
}


# ==============================================================
#  RESTORE
# ==============================================================
function Invoke-Restore {

    Out-Header 'DHCP TABLE RESTORE  v4.1'
    Write-Host "  Script dir  : ${ScriptDir}"
    Write-Host "  Backups root: ${BackupsRoot}"
    Write-Host "  Log file    : ${LogFile}"
    Write-Host ''

    Write-Log '=================================================='
    Write-Log 'Restore session start'
    Write-Log "Script dir   : ${ScriptDir}"
    Write-Log "Backups root : ${BackupsRoot}"
    Write-OSVersion
    Write-Log '=================================================='

    if (-not (Test-Path $BackupsRoot)) {
        Out-Banner '[X] ERROR: Backups folder not found.' Red
        Out-Banner "    Expected: ${BackupsRoot}" Red
        Out-Banner '    Run Backup first to create backups.' Yellow
        Write-Log 'ERROR: Backups root not found.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # List Server/Location folders
    $locFolders = @(Get-ChildItem $BackupsRoot -Directory -ErrorAction SilentlyContinue)
    if ($locFolders.Count -eq 0) {
        Out-Banner '[!] No Server/Location folders found. Run Backup first.' Yellow
        Write-Log 'ERROR: No location folders found.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Write-Host '  Available Server / Location backups:'
    Write-Host '  --------------------------------------------------'
    Write-Host ''
    for ($i = 0; $i -lt $locFolders.Count; $i++) {
        $cnt = @(Get-ChildItem $locFolders[$i].FullName -Filter '*.txt' -ErrorAction SilentlyContinue).Count
        Write-Host "    [$($i+1)]  $($locFolders[$i].Name)   ($cnt backup file(s))"
    }
    Write-Host ''

    $locIdx    = Select-FromList '  Select Server/Location number' $locFolders.Count
    if ($locIdx -eq -1) {
        Out-Banner '[i] Restore cancelled.' Cyan
        Write-Log 'Restore: cancelled at location selection.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    $selFolder = $locFolders[$locIdx]
    $selLoc    = $selFolder.Name
    Write-Log "Location selected: $selLoc"
    Write-Host ''
    Out-Banner "[*] Selected: $selLoc" Cyan
    Write-Host ''

    # List backup files, newest first
    $files = @(Get-ChildItem $selFolder.FullName -Filter '*.txt' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)

    if ($files.Count -eq 0) {
        Out-Banner "[!] No .txt backup files found for: $selLoc" Yellow
        Write-Log "ERROR: No .txt files in $($selFolder.FullName)"
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Write-Host "  Backup files for `"$selLoc`"  (newest first):"
    Write-Host '  --------------------------------------------------'
    Write-Host ''

    for ($i = 0; $i -lt $files.Count; $i++) {
        $f     = $files[$i]
        $kb    = [math]::Round($f.Length / 1KB, 1)
        $dt    = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $base  = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $hasSC = Test-Path (Join-Path $f.DirectoryName "$base.sha256")
        $scTag = if ($hasSC) { '[hash sidecar present]' } else { '[NO sidecar]' }
        Write-Host "    [$($i+1)]  $($f.Name)  $scTag"
        Write-Host "          Date : $dt    Size : $kb KB"
        Write-Host ''
    }

    $fileIdx = Select-FromList '  Select file number to restore from' $files.Count
    if ($fileIdx -eq -1) {
        Out-Banner '[i] Restore cancelled.' Cyan
        Write-Log 'Restore: cancelled at file selection.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    $restoreF     = $files[$fileIdx]
    $restorePath  = $restoreF.FullName
    $restoreFname = $restoreF.Name
    $relRestore   = "Backups\$selLoc\$restoreFname"
    Write-Log "File selected: ${restorePath}"

    # Hash verification
    Write-Host ''
    Out-Banner '[*] Verifying backup file integrity before restore...' Cyan
    Write-Host ''

    $vr = Test-HashSidecar -TxtPath $restorePath

    if ($vr.Ok) {
        Out-Banner '[+] Hash verification PASSED.' Green
        Write-Host "    Stored hash : $($vr.StoredHash)"
        Write-Host "    Live hash   : $($vr.LiveHash)"
        Write-Log "Hash verification PASSED. Hash: $($vr.LiveHash)"
    }
    else {
        Write-Host ''
        Out-Banner '[X] Hash verification FAILED!' Red
        Out-Banner "    Reason: $($vr.Reason)" Red
        Write-Host ''
        Out-Banner '    The backup file may be corrupted or tampered with.' Yellow
        Out-Banner '    Restoring a corrupted file can break DHCP on this server.' Yellow
        Write-Host ''
        Write-Log "Hash verification FAILED: $($vr.Reason)"

        $override = (Read-Host '  Restore anyway? NOT recommended. Type OVERRIDE to proceed').Trim()
        if ($override -cne 'OVERRIDE') {
            Out-Banner '[!] Restore aborted. No changes were made.' Yellow
            Write-Log 'Restore aborted by user after hash failure.'
            Write-Host ''
            Read-Host '  Press Enter to return to menu'
            return
        }
        Write-Log 'WARNING: User chose OVERRIDE after hash failure.'
    }

    # Confirmation
    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Red
    Write-Host '   !!!  WARNING - DESTRUCTIVE OPERATION  !!!' -ForegroundColor Red
    Write-Host '  ==================================================' -ForegroundColor Red
    Write-Host ''
    Write-Host '   You are about to OVERWRITE the live DHCP'
    Write-Host '   configuration on this server.'
    Write-Host ''
    Write-Host "   Server / Location : $selLoc"
    Write-Host "   Restore file      : $restoreFname"
    Write-Host "   Relative path     : $relRestore"
    Write-Host ''
    Write-Host '   This action cannot be undone.'
    Write-Host '  ==================================================' -ForegroundColor Red
    Write-Host ''

    if ((Read-Host '  Type  YES  (all capitals) to confirm').Trim() -cne 'YES') {
        Out-Banner '[!] Restore cancelled. Nothing was changed.' Yellow
        Write-Log 'Restore cancelled at confirmation prompt.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Write-Host ''
    Write-Log 'User confirmed restore. Proceeding...'

    # -- Pre-restore: offer to delete existing scopes ----------
    # A clean restore requires removing existing scopes first.
    # netsh import merges rather than replaces, which can leave
    # ghost scopes from the old configuration behind.
    Write-Host ''
    Out-Header 'PRE-RESTORE: SCOPE CLEANUP'
    Out-Banner '[*] Probing DHCP server for existing scopes...' Cyan
    Write-Host ''

    $existingScopes = @(Get-DhcpScopes)

    if ($existingScopes.Count -eq 0) {
        Out-Banner '[i] No existing scopes found. Proceeding directly to import.' Cyan
        Write-Log 'Pre-restore scope check: no scopes found.'
    }
    else {
        Write-Host "  Found $($existingScopes.Count) existing scope(s):" -ForegroundColor Yellow
        Write-Host ''
        for ($si = 0; $si -lt $existingScopes.Count; $si++) {
            $sc = $existingScopes[$si]
            Write-Host "    [$($si+1)]  $($sc.ScopeId)  Mask: $($sc.Mask)  State: $($sc.State)  Name: $($sc.Name)"
        }
        Write-Host ''
        Write-Host '  Existing scopes should be deleted before import to avoid' -ForegroundColor Yellow
        Write-Host '  merge conflicts.  It is strongly recommended to delete them now.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    [1]  Delete ALL existing scopes (recommended)'
        Write-Host '    [2]  Select specific scopes to delete'
        Write-Host '    [3]  Skip - import without deleting (not recommended)'
        Write-Host ''

        $scopeChoice = Select-FromList '  Select option' 3

        if ($scopeChoice -eq -1) {
            Out-Banner '[i] Restore cancelled at scope-cleanup step.' Cyan
            Write-Log 'Restore: cancelled at pre-restore scope cleanup.'
            Write-Host ''
            Read-Host '  Press Enter to return to menu'
            return
        }

        if ($scopeChoice -eq 0) {
            # Delete all scopes
            Write-Host ''
            Out-Banner '[*] Deleting all existing scopes...' Cyan
            Write-Log "Pre-restore: deleting all $($existingScopes.Count) scope(s)."
            $scopeErrors = 0
            foreach ($sc in $existingScopes) {
                Out-Banner "[*] Deleting scope $($sc.ScopeId) ($($sc.Name))..." Cyan
                $ok = Remove-DhcpScope -ScopeId $sc.ScopeId -Version $sc.Version
                if ($ok) {
                    Out-Banner "[+] Deleted scope: $($sc.ScopeId)" Green
                    Write-Log "Pre-restore: deleted scope $($sc.ScopeId)."
                }
                else {
                    Out-Banner "[X] Failed to delete scope: $($sc.ScopeId)" Red
                    Write-Log "Pre-restore ERROR: could not delete scope $($sc.ScopeId)."
                    $scopeErrors++
                }
            }
            if ($scopeErrors -gt 0) {
                Out-Banner "[!] $scopeErrors scope(s) could not be deleted. Review log." Yellow
            }
            else {
                Out-Banner '[+] All existing scopes deleted successfully.' Green
            }
        }
        elseif ($scopeChoice -eq 1) {
            # Select specific scopes
            Write-Host ''
            Write-Host '  Enter scope numbers to delete (comma-separated, e.g. 1,3):'
            $rawSel = (Read-Host '  Scopes to delete').Trim()
            $selectedIndices = @()
            foreach ($part in ($rawSel -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $existingScopes.Count) {
                    $selectedIndices += ($n - 1)
                }
            }
            if ($selectedIndices.Count -eq 0) {
                Out-Banner '[!] No valid selections. Skipping scope deletion.' Yellow
                Write-Log 'Pre-restore: no valid scope selections entered, skipping.'
            }
            else {
                Write-Host ''
                Out-Banner '[*] Deleting selected scopes...' Cyan
                foreach ($idx in $selectedIndices) {
                    $sc = $existingScopes[$idx]
                    Out-Banner "[*] Deleting scope $($sc.ScopeId) ($($sc.Name))..." Cyan
                    $ok = Remove-DhcpScope -ScopeId $sc.ScopeId -Version $sc.Version
                    if ($ok) {
                        Out-Banner "[+] Deleted scope: $($sc.ScopeId)" Green
                        Write-Log "Pre-restore: deleted scope $($sc.ScopeId)."
                    }
                    else {
                        Out-Banner "[X] Failed to delete scope: $($sc.ScopeId)" Red
                        Write-Log "Pre-restore ERROR: could not delete scope $($sc.ScopeId)."
                    }
                }
            }
        }
        else {
            Out-Banner '[!] Skipping scope deletion. Import may result in merged/duplicate scopes.' Yellow
            Write-Log 'Pre-restore: user chose to skip scope deletion.'
        }
    }

    Write-Host ''

    # Import
    Out-Banner '[*] Importing DHCP table - please wait...' Cyan
    Write-Host ''
    Write-Log "Running: netsh dhcp server import ${restorePath} all"

    $netshOut  = & netsh dhcp server import $restorePath all 2>&1
    $netshExit = $LASTEXITCODE
    Write-Log "netsh exit   : $netshExit"
    Write-Log "netsh output : $($netshOut -join ' | ')"

    if ($netshExit -ne 0) {
        Out-Banner "[X] ERROR: DHCP import FAILED (exit code: $netshExit)." Red
        Out-Banner "    Output: $($netshOut -join ' ')" Yellow
        Out-Banner '    Possible causes:' Yellow
        Out-Banner '      - DHCP Server role not installed' Yellow
        Out-Banner '      - DHCP Server service not running' Yellow
        Out-Banner '      - File corrupted or from incompatible OS version' Yellow
        Write-Log "ERROR: netsh import exit code: $netshExit"
        Write-Log '--- Restore FAILED ---'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Out-Banner '[+] DHCP table imported successfully.' Green
    Write-Log 'DHCP import OK.'

    # Restart DHCP service
    Write-Host ''
    Out-Banner '[*] Stopping DHCP Server service...' Cyan
    Write-Log 'Stopping DHCPServer...'
    Stop-Service -Name DHCPServer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    Out-Banner '[*] Starting DHCP Server service...' Cyan
    Write-Log 'Starting DHCPServer...'
    try {
        Start-Service -Name DHCPServer -ErrorAction Stop
        Out-Banner '[+] DHCP Server service restarted successfully.' Green
        Write-Log 'DHCPServer restarted OK.'
    }
    catch {
        Out-Banner '[!] WARNING: Could not restart DHCP service automatically.' Yellow
        Out-Banner "    Error: $_" Yellow
        Out-Banner '    Opening Services console - please restart manually.' Yellow
        Write-Log "WARNING: DHCPServer restart failed: $_"
        Start-Process services.msc
    }

    Save-RestoreConfig -Location     $selLoc       `
                       -FileName     $restoreFname  `
                       -RelativePath $relRestore

    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Green
    Write-Host '    RESTORE COMPLETED SUCCESSFULLY' -ForegroundColor Green
    Write-Host '  ==================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host "   Server / Location : $selLoc"
    Write-Host "   Restored from     : $relRestore"
    Write-Host "   Log               : ${LogFile}"
    Write-Host ''
    Write-Log "--- Restore COMPLETED: $selLoc from $restoreFname ---"
    Write-Log '=================================================='

    Read-Host '  Press Enter to return to menu'
}


# ==============================================================
#  DELETE OLD BACKUPS
# ==============================================================
function Invoke-Delete {

    Out-Header 'DELETE OLD BACKUPS  v4.1'
    Write-Host "  Backups root: ${BackupsRoot}"
    Write-Host "  Log file    : ${LogFile}"
    Write-Host ''

    Write-Log '=================================================='
    Write-Log 'Delete session start'

    if (-not (Test-Path $BackupsRoot)) {
        Out-Banner '[!] Backups folder not found. Nothing to delete.' Yellow
        Write-Log 'ERROR: Backups root not found.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    $locFolders = @(Get-ChildItem $BackupsRoot -Directory -ErrorAction SilentlyContinue)
    if ($locFolders.Count -eq 0) {
        Out-Banner '[!] No Server/Location folders found.' Yellow
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # Select Server/Location
    Write-Host '  Server / Location folders:'
    Write-Host '  --------------------------------------------------'
    Write-Host ''
    for ($i = 0; $i -lt $locFolders.Count; $i++) {
        $cnt = @(Get-ChildItem $locFolders[$i].FullName -Filter '*.txt' -ErrorAction SilentlyContinue).Count
        Write-Host "    [$($i+1)]  $($locFolders[$i].Name)   ($cnt backup file(s))"
    }
    Write-Host ''

    $locIdx    = Select-FromList '  Select Server/Location number' $locFolders.Count
    if ($locIdx -eq -1) {
        Out-Banner '[i] Cancelled. No files were deleted.' Cyan
        Write-Log 'Delete: cancelled at location selection.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    $selFolder = $locFolders[$locIdx]
    $selLoc    = $selFolder.Name
    Write-Log "Delete - location: $selLoc"
    Write-Host ''

    # Delete mode
    Write-Host '  What would you like to delete?'
    Write-Host ''
    Write-Host '    [1]  Delete a specific backup set (.txt + .bak + .sha256)'
    Write-Host '    [2]  Delete ALL backups for this location (entire folder)'
    Write-Host '    [3]  Cancel'
    Write-Host ''

    $delMode = Select-FromList '  Select option' 3

    # Cancel (0 from helper or [3] from menu)
    if ($delMode -eq -1 -or $delMode -eq 2) {
        Out-Banner '[i] Delete cancelled.' Cyan
        Write-Log 'Delete cancelled.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # Delete entire location folder
    if ($delMode -eq 1) {
        Write-Host ''
        Write-Host '  ==================================================' -ForegroundColor Red
        Write-Host "   WARNING: Delete ALL backups for: $selLoc" -ForegroundColor Red
        Write-Host '   This permanently removes the entire folder.' -ForegroundColor Red
        Write-Host '  ==================================================' -ForegroundColor Red
        Write-Host ''
        $allFiles = @(Get-ChildItem $selFolder.FullName -ErrorAction SilentlyContinue)
        foreach ($f in $allFiles) { Write-Host "   Will delete: $($f.Name)" }
        Write-Host ''

        if ((Read-Host '  Type  DELETE  (all capitals) to confirm').Trim() -cne 'DELETE') {
            Out-Banner '[i] Deletion cancelled. Nothing was removed.' Cyan
            Write-Log "Delete ALL cancelled for: $selLoc"
            Write-Host ''
            Read-Host '  Press Enter to return to menu'
            return
        }

        Write-Log "Deleting entire folder: $($selFolder.FullName)"
        try {
            Remove-Item $selFolder.FullName -Recurse -Force -ErrorAction Stop
            Out-Banner "[+] Deleted folder: $($selFolder.FullName)" Green
            Write-Log "Deleted folder: $($selFolder.FullName)"
        }
        catch {
            Out-Banner "[X] ERROR: Could not delete folder: $_" Red
            Write-Log "ERROR: Folder delete failed: $_"
        }

        Write-Host ''
        Write-Log '--- Delete ALL completed ---'
        Write-Log '=================================================='
        Read-Host '  Press Enter to return to menu'
        return
    }

    # Delete specific backup set
    $txtFiles = @(Get-ChildItem $selFolder.FullName -Filter '*.txt' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)

    if ($txtFiles.Count -eq 0) {
        Out-Banner "[!] No backup files found for: $selLoc" Yellow
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Write-Host ''
    Write-Host "  Backup files for `"$selLoc`"  (newest first):"
    Write-Host '  --------------------------------------------------'
    Write-Host ''

    for ($i = 0; $i -lt $txtFiles.Count; $i++) {
        $f    = $txtFiles[$i]
        $kb   = [math]::Round($f.Length / 1KB, 1)
        $dt   = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $tags = @()
        if (Test-Path (Join-Path $f.DirectoryName "$base.bak"))    { $tags += '.bak'    }
        if (Test-Path (Join-Path $f.DirectoryName "$base.sha256")) { $tags += '.sha256' }
        $note = if ($tags.Count -gt 0) { "  [also: $($tags -join ', ')]" } else { '' }
        Write-Host "    [$($i+1)]  $($f.Name)$note"
        Write-Host "          Date : $dt    Size : $kb KB"
        Write-Host ''
    }

    $fileIdx = Select-FromList '  Select file number to delete' $txtFiles.Count
    if ($fileIdx -eq -1) {
        Out-Banner '[i] Cancelled. No files were deleted.' Cyan
        Write-Log 'Delete: cancelled at file selection.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    $delFile = $txtFiles[$fileIdx]
    $delBase = [System.IO.Path]::GetFileNameWithoutExtension($delFile.Name)
    $delBak  = Join-Path $selFolder.FullName "$delBase.bak"
    $delSC   = Join-Path $selFolder.FullName "$delBase.sha256"

    Write-Host ''
    Write-Host '  Files that will be permanently deleted:' -ForegroundColor Yellow
    Write-Host "    $($delFile.FullName)"
    if (Test-Path $delBak) { Write-Host "    ${delBak}" }
    if (Test-Path $delSC)  { Write-Host "    ${delSC}"  }
    Write-Host ''

    if ((Read-Host '  Type  DELETE  (all capitals) to confirm').Trim() -cne 'DELETE') {
        Out-Banner '[i] Deletion cancelled. Nothing was removed.' Cyan
        Write-Log "Delete single cancelled: $($delFile.Name)"
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    $deletedCount = 0
    foreach ($target in @($delFile.FullName, $delBak, $delSC)) {
        if (Test-Path $target) {
            try {
                Remove-Item $target -Force -ErrorAction Stop
                Out-Banner "[+] Deleted: $(Split-Path ${target} -Leaf)" Green
                Write-Log "Deleted: ${target}"
                $deletedCount++
            }
            catch {
                Out-Banner "[X] ERROR deleting $(Split-Path ${target} -Leaf): $_" Red
                Write-Log "ERROR deleting ${target}: $_"
            }
        }
    }

    # Offer to remove empty folder
    $remaining = @(Get-ChildItem $selFolder.FullName -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Write-Host ''
        Out-Banner "[i] The folder '$selLoc' is now empty." Cyan
        if ((Read-Host '  Remove the empty folder too? [Y/N]').Trim() -match '^[Yy]$') {
            try {
                Remove-Item $selFolder.FullName -Force -ErrorAction Stop
                Out-Banner "[+] Removed empty folder: $($selFolder.FullName)" Green
                Write-Log "Removed empty folder: $($selFolder.FullName)"
            }
            catch {
                Out-Banner "[X] Could not remove folder: $_" Red
                Write-Log "ERROR removing empty folder: $_"
            }
        }
    }

    Write-Host ''
    Out-Banner "[+] Delete complete. $deletedCount file(s) removed." Green
    Write-Log "--- Delete completed: $deletedCount file(s) for $selLoc ---"
    Write-Log '=================================================='

    Read-Host '  Press Enter to return to menu'
}


# ==============================================================
#  DELETE DHCP SCOPE
#  Probes the live DHCP server for all scopes, presents them
#  to the user, and deletes selected ones after confirmation.
#  Supports both IPv4 and IPv6.  Works on WS2012 and newer.
# ==============================================================
function Invoke-DeleteScope {

    Out-Header 'DELETE EXISTING DHCP SCOPE  v5.0'
    Write-Host "  Log file    : ${LogFile}"
    Write-Host ''

    Write-Log '=================================================='
    Write-Log 'DeleteScope session start'
    Write-OSVersion
    Write-Log '=================================================='

    if (-not (Test-DhcpService)) {
        Out-Banner '[X] ERROR: DHCP Server service not found on this machine.' Red
        Out-Banner '    The DHCP Server role must be installed to manage scopes.' Red
        Write-Log 'ERROR: DHCPServer service not found.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # Probe server for scopes
    Out-Banner '[*] Querying DHCP server for existing scopes...' Cyan
    Write-Host ''

    $scopes = @(Get-DhcpScopes)

    if ($scopes.Count -eq 0) {
        Out-Banner '[i] No DHCP scopes found on this server.' Cyan
        Write-Log 'DeleteScope: no scopes found.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Write-Host "  Found $($scopes.Count) scope(s):"
    Write-Host '  --------------------------------------------------'
    Write-Host ''
    for ($i = 0; $i -lt $scopes.Count; $i++) {
        $s = $scopes[$i]
        Write-Host "    [$($i+1)]  $($s.Version.PadRight(4))  $($s.ScopeId.PadRight(18))  Mask: $($s.Mask.PadRight(18))  State: $($s.State.PadRight(8))  Name: $($s.Name)"
    }
    Write-Host ''

    # What to delete
    Write-Host '  What would you like to delete?'
    Write-Host ''
    Write-Host '    [1]  Delete a specific scope'
    Write-Host '    [2]  Delete ALL scopes'
    Write-Host '    [3]  Cancel'
    Write-Host ''

    $delChoice = Select-FromList '  Select option' 3

    # Cancel (0 from helper or [3] from menu)
    if ($delChoice -eq -1 -or $delChoice -eq 2) {
        Out-Banner '[i] Cancelled. No scopes were deleted.' Cyan
        Write-Log 'DeleteScope: cancelled by user.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # -- Delete ALL scopes --
    if ($delChoice -eq 1) {
        Write-Host ''
        Write-Host '  ==================================================' -ForegroundColor Red
        Write-Host '   WARNING: You are about to delete ALL DHCP scopes.' -ForegroundColor Red
        Write-Host '   All IP address leases will be permanently removed.' -ForegroundColor Red
        Write-Host '  ==================================================' -ForegroundColor Red
        Write-Host ''
        foreach ($s in $scopes) {
            Write-Host "   Will delete: $($s.ScopeId)  ($($s.Name))"
        }
        Write-Host ''

        if ((Read-Host '  Type  DELETE  (all capitals) to confirm').Trim() -cne 'DELETE') {
            Out-Banner '[i] Cancelled. No scopes were deleted.' Cyan
            Write-Log 'DeleteScope ALL: cancelled at confirmation.'
            Write-Host ''
            Read-Host '  Press Enter to return to menu'
            return
        }

        Write-Host ''
        Out-Banner '[*] Deleting all scopes...' Cyan
        Write-Log "DeleteScope: deleting all $($scopes.Count) scope(s)."
        $errCount = 0
        foreach ($s in $scopes) {
            Out-Banner "[*] Deleting $($s.ScopeId) ($($s.Name))..." Cyan
            $ok = Remove-DhcpScope -ScopeId $s.ScopeId -Version $s.Version
            if ($ok) {
                Out-Banner "[+] Deleted: $($s.ScopeId)" Green
                Write-Log "DeleteScope: deleted $($s.ScopeId)."
            }
            else {
                Out-Banner "[X] Failed to delete: $($s.ScopeId)" Red
                Write-Log "DeleteScope ERROR: could not delete $($s.ScopeId)."
                $errCount++
            }
        }

        Write-Host ''
        if ($errCount -eq 0) {
            Out-Banner "[+] All $($scopes.Count) scope(s) deleted successfully." Green
        }
        else {
            Out-Banner "[!] Completed with $errCount error(s). Check log for details." Yellow
        }
        Write-Log "DeleteScope ALL: done. Errors: $errCount."
        Write-Log '=================================================='
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # -- Delete a specific scope --
    $idx = Select-FromList '  Select scope number to delete' $scopes.Count
    if ($idx -eq -1) {
        Out-Banner '[i] Cancelled. No scopes were deleted.' Cyan
        Write-Log 'DeleteScope: cancelled at scope selection.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }
    $sel = $scopes[$idx]

    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Red
    Write-Host "   Scope to delete  : $($sel.ScopeId)  ($($sel.Name))" -ForegroundColor Red
    Write-Host "   Version          : $($sel.Version)" -ForegroundColor Red
    Write-Host "   State            : $($sel.State)" -ForegroundColor Red
    Write-Host '   All leases for this scope will be permanently removed.' -ForegroundColor Red
    Write-Host '  ==================================================' -ForegroundColor Red
    Write-Host ''

    if ((Read-Host '  Type  DELETE  (all capitals) to confirm').Trim() -cne 'DELETE') {
        Out-Banner '[i] Cancelled. Scope was not deleted.' Cyan
        Write-Log "DeleteScope: cancelled for $($sel.ScopeId)."
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    Write-Host ''
    Out-Banner "[*] Deleting scope $($sel.ScopeId)..." Cyan
    $ok = Remove-DhcpScope -ScopeId $sel.ScopeId -Version $sel.Version

    if ($ok) {
        Out-Banner "[+] Scope $($sel.ScopeId) deleted successfully." Green
        Write-Log "DeleteScope: deleted $($sel.ScopeId) successfully."
    }
    else {
        Out-Banner "[X] Failed to delete scope $($sel.ScopeId). Check log." Red
        Write-Log "DeleteScope ERROR: delete failed for $($sel.ScopeId)."
    }

    Write-Host ''
    Write-Log '=================================================='
    Read-Host '  Press Enter to return to menu'
}


# ==============================================================
#  DHCP SERVICE MANAGER
#  Displays the current service status and lets the user
#  Start, Stop, or Restart the DHCP Server service interactively.
# ==============================================================
function Invoke-ServiceManager {

    Out-Header 'DHCP SERVICE MANAGER  v5.0'
    Write-Host "  Log file    : ${LogFile}"
    Write-Host ''

    Write-Log '=================================================='
    Write-Log 'ServiceManager session start'
    Write-Log '=================================================='

    if (-not (Test-DhcpService)) {
        Out-Banner '[X] ERROR: DHCP Server service not found on this machine.' Red
        Out-Banner '    The DHCP Server role must be installed.' Red
        Write-Log 'ERROR: DHCPServer service not found.'
        Write-Host ''
        Read-Host '  Press Enter to return to menu'
        return
    }

    # Inner helper: print current status with colour
    function Show-DhcpStatus {
        $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Host '   Current status : NOT FOUND' -ForegroundColor Red
            return
        }
        $color = switch ($svc.Status) {
            'Running' { 'Green'  }
            'Stopped' { 'Red'    }
            default   { 'Yellow' }
        }
        Write-Host "   Current status : $($svc.Status)" -ForegroundColor $color
        Write-Host "   Display name   : $($svc.DisplayName)"
        Write-Host "   Start type     : $($svc.StartType)"
    }

    do {
        Write-Host ''
        Write-Host '  DHCP Server Service Status:'
        Write-Host '  --------------------------------------------------'
        Show-DhcpStatus
        Write-Host ''
        Write-Host '  Actions:'
        Write-Host ''
        Write-Host '    [1]  Start   the DHCP Server service'
        Write-Host '    [2]  Stop    the DHCP Server service'
        Write-Host '    [3]  Restart the DHCP Server service'
        Write-Host '    [4]  Refresh status display'
        Write-Host '    [5]  Return to main menu'
        Write-Host ''

        $action = Select-FromList '  Select action' 5
        if ($action -eq -1) {
            Write-Log 'ServiceManager session end (cancelled).'
            Write-Log '=================================================='
            return
        }

        switch ($action) {
            0 {
                # Start
                Out-Banner '[*] Starting DHCP Server service...' Cyan
                Write-Log 'ServiceManager: Starting DHCPServer.'
                try {
                    Start-Service -Name DHCPServer -ErrorAction Stop
                    Out-Banner '[+] DHCP Server service started.' Green
                    Write-Log 'ServiceManager: DHCPServer started OK.'
                }
                catch {
                    Out-Banner "[X] Failed to start service: $_" Red
                    Write-Log "ServiceManager ERROR: start failed: $_"
                }
            }
            1 {
                # Stop
                Write-Host ''
                Out-Banner '[!] Stopping DHCP will interrupt IP address leasing.' Yellow
                $conf = (Read-Host '  Type  STOP  to confirm').Trim()
                if ($conf -ceq 'STOP') {
                    Out-Banner '[*] Stopping DHCP Server service...' Cyan
                    Write-Log 'ServiceManager: Stopping DHCPServer.'
                    try {
                        Stop-Service -Name DHCPServer -Force -ErrorAction Stop
                        Out-Banner '[+] DHCP Server service stopped.' Green
                        Write-Log 'ServiceManager: DHCPServer stopped OK.'
                    }
                    catch {
                        Out-Banner "[X] Failed to stop service: $_" Red
                        Write-Log "ServiceManager ERROR: stop failed: $_"
                    }
                }
                else {
                    Out-Banner '[i] Stop cancelled.' Cyan
                    Write-Log 'ServiceManager: Stop cancelled by user.'
                }
            }
            2 {
                # Restart
                Out-Banner '[*] Stopping DHCP Server service...' Cyan
                Write-Log 'ServiceManager: Restarting DHCPServer - stop phase.'
                Stop-Service -Name DHCPServer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                Out-Banner '[*] Starting DHCP Server service...' Cyan
                Write-Log 'ServiceManager: Restarting DHCPServer - start phase.'
                try {
                    Start-Service -Name DHCPServer -ErrorAction Stop
                    Out-Banner '[+] DHCP Server service restarted.' Green
                    Write-Log 'ServiceManager: DHCPServer restarted OK.'
                }
                catch {
                    Out-Banner "[X] Failed to restart service: $_" Red
                    Write-Log "ServiceManager ERROR: restart failed: $_"
                }
            }
            3 { <# Refresh - loop naturally #> }
            4 {
                # Return to menu
                Write-Log 'ServiceManager session end.'
                Write-Log '=================================================='
                return
            }
        }

        Write-Host ''
        Start-Sleep -Milliseconds 500

    } while ($true)
}


# ==============================================================
#  INTERACTIVE MENU
# ==============================================================
function Show-Menu {
    do {
        Clear-Host
        Write-Host ''
        Write-Host '  ==================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '         DHCP Backup & Restore Utility  v5.0' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  ==================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    What do you want to do today?'
        Write-Host ''
        Write-Host '    [1]  Backup          --  Export and save DHCP table'
        Write-Host '    [2]  Restore         --  Import DHCP table from backup'
        Write-Host '    [3]  Delete Backups  --  Remove old backup files'
        Write-Host '    [4]  Delete Scope    --  Remove existing DHCP scope(s)'
        Write-Host '    [5]  DHCP Service    --  Start / Stop / Restart DHCP Server'
        Write-Host '    [6]  Exit'
        Write-Host ''
        Write-Host '  --------------------------------------------------'
        Write-Host ''

        $choice = (Read-Host '  Enter your choice [1-6]').Trim()

        switch ($choice) {
            '1' { Invoke-Backup         }
            '2' { Invoke-Restore        }
            '3' { Invoke-Delete         }
            '4' { Invoke-DeleteScope    }
            '5' { Invoke-ServiceManager }
            '6' { return }
            default {
                Out-Banner '[!] Invalid choice. Please enter 1 through 6.' Yellow
                Start-Sleep -Seconds 2
            }
        }
    } while ($true)
}


# ==============================================================
#  ENTRY POINT
# ==============================================================
switch ($Mode) {
    'Backup'         { Invoke-Backup         }
    'Restore'        { Invoke-Restore        }
    'Delete'         { Invoke-Delete         }
    'DeleteScope'    { Invoke-DeleteScope    }
    'ServiceManager' { Invoke-ServiceManager }
    'Menu'           { Show-Menu             }
}
