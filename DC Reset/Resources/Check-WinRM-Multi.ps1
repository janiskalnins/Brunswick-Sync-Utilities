<#
.SYNOPSIS
  Checks WinRM availability on multiple computers (legacy-friendly).

.DESCRIPTION
  - Expands compact name ranges: e.g., "DC1-2, DC3-4" => DC1, DC2, DC3, DC4
  - Uses Test-WSMan (if available), ICMP ping, raw TCP (5985/5986), and WMI WinRM service status
  - Compatible with older systems (PowerShell 2.0+)

.PARAMETER Computers
  Comma-separated list of computers or range tokens like DC1-2, DC3-4

.PARAMETER TimeoutMs
  TCP connect timeout in milliseconds (default 1500)

.PARAMETER CsvPath
  Optional output CSV path. Default: .\WinRM_Check_<timestamp>.csv

.EXAMPLE
  .\Check-WinRM-Multi.ps1 -Computers "'DC1-2', 'DC3-4', 'DC5-6', 'DC7-8'"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Computers,

    [int]$TimeoutMs = 1500,

    [string]$CsvPath
)

# -------- Helpers --------

function Expand-ComputerRange {
    param([string[]]$Tokens)

    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Tokens) {
        $trim = $t
        if ($trim -eq $null) { continue }
        $trim = $trim.Trim()
        if (($trim -replace '\s','') -eq '') { continue }

        # Pattern: PREFIX<start>-<end>, e.g., DC1-4 (letters/hyphen prefix + integers)
        if ($trim -match '^(?<prefix>[A-Za-z\-]+?)(?<start>\d+)-(?<end>\d+)$') {
            $prefix = $matches['prefix']
            $start = [int]$matches['start']
            $end   = [int]$matches['end']

            if ($end -lt $start) {
                $tmp = $start; $start = $end; $end = $tmp
            }
            for ($i=$start; $i -le $end; $i++) {
                $expanded.Add("$prefix$i")
            }
        }
        else {
            # Pass-through single name or any token not matching the simple range pattern
            $expanded.Add($trim)
        }
    }
    return $expanded
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][int]$Port,
        [int]$TimeoutMs = 1500
    )
    # Legacy-friendly TCP connect with timeout
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.Close()
            return $false
        }
        $client.EndConnect($iar)
        return $true
    }
    catch { 
        return $false 
    }
    finally {
        try { $client.Close() } catch {}
    }
}

function Safe-TestWSMan {
    param([string]$ComputerName)
    try {
        $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        return $true
    }
    catch { 
        return $false 
    }
}

function Safe-Ping {
    param([string]$ComputerName)
    try { 
        return (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }
    catch { 
        return $false 
    }
}

function Get-WinRMServiceStatusWMI {
    param([string]$ComputerName)
    try {
        $svc = Get-WmiObject -Class Win32_Service -ComputerName $ComputerName -Filter "Name='WinRM'" -ErrorAction Stop
        if ($svc -and $svc.State) { 
            return $svc.State  # e.g., Running, Stopped, Paused
        }
        else { 
            return $null 
        }
    }
    catch { 
        return $null 
    }
}

# -------- Main --------

# Expand input list like "DC1-2, DC3-4, DC5-6, DC7-8"
$tokens = $Computers -split ','
$targets = Expand-ComputerRange -Tokens $tokens | Select-Object -Unique

if (-not $targets -or $targets.Count -eq 0) {
    Write-Error "No valid computer names were provided."
    exit 1
}

if (-not $CsvPath -or ($CsvPath -replace '\s','') -eq '') {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $CsvPath = Join-Path -Path (Get-Location) -ChildPath ("WinRM_Check_{0}.csv" -f $stamp)
}

$results = @()

Write-Host ("Checking WinRM on {0} computer(s)..." -f $targets.Count) -ForegroundColor Cyan
Write-Host ""

foreach ($c in $targets) {
    $reachable = Safe-Ping -ComputerName $c

    # Try WSMan first if reachable
    $wsmanOk = $false
    if ($reachable) {
        $wsmanOk = Safe-TestWSMan -ComputerName $c
    }

    # TCP checks (HTTP/HTTPS listeners)
    $port5985 = Test-TcpPort -ComputerName $c -Port 5985 -TimeoutMs $TimeoutMs
    $port5986 = Test-TcpPort -ComputerName $c -Port 5986 -TimeoutMs $TimeoutMs

    # WMI WinRM service state (works even if WinRM is off, provided RPC allowed)
    $svcState = Get-WinRMServiceStatusWMI -ComputerName $c
    $svcText = 'N/A'
    if ($svcState -ne $null -and $svcState -ne '') { $svcText = $svcState }

    $notes = New-Object System.Collections.Generic.List[string]
    if (-not $reachable) { $notes.Add("No ICMP reply") }
    if ($port5985 -and -not $wsmanOk) { $notes.Add("5985 open but WSMan not responding") }
    if (-not $port5985 -and -not $port5986) { $notes.Add("No WinRM ports open") }
    if ($svcState) { $notes.Add("WinRM service: $svcState") }

    $obj = New-Object PSObject -Property @{
        ComputerName   = $c
        Reachable      = [bool]$reachable
        WinRM_Responds = [bool]$wsmanOk
        Port_5985_Open = [bool]$port5985
        Port_5986_Open = [bool]$port5986
        WinRM_Service  = $svcState
        Notes          = ($notes -join "; ")
    }

    # Console summary line (ASCII only; no line continuations)
    if ($wsmanOk) {
        Write-Host ("[{0}] [OK] WinRM responding" -f $c) -ForegroundColor Green
    }
    else {
        Write-Host ("[{0}] [FAIL] WinRM not responding" -f $c) -ForegroundColor Yellow
        Write-Host ("       Reachable: {0}, 5985: {1}, 5986: {2}, Service: {3}" -f $reachable, $port5985, $port5986, $svcText) -ForegroundColor DarkGray
        if ($notes.Count -gt 0) {
            Write-Host ("       Notes: {0}" -f ($notes -join "; ")) -ForegroundColor DarkGray
        }
    }

    $results += $obj
}

# Export
try {
    $results | Sort-Object ComputerName | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host ""
    Write-Host ("Results saved to: {0}" -f $CsvPath) -ForegroundColor Cyan
}
catch {
    Write-Warning ("Could not write CSV to {0}. {1}" -f $CsvPath, $_.Exception.Message)
}

# Return objects to pipeline if run in-session
$results