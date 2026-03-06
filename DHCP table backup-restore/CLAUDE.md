# CLAUDE.md — Project Guidance for Claude Code

This file tells Claude Code how to work correctly with this project.
Read it in full before making any changes to the source files.

---

## Project Summary

A two-file portable Windows DHCP backup/restore utility.

| File | Role |
|---|---|
| `DHCP_Launcher.cmd` | CMD batch launcher. Self-elevates via UAC, shows a menu, calls `DHCP_Utility.ps1 -Mode <X>`. |
| `DHCP_Utility.ps1` | All logic. PowerShell 3.0+. Backup, Restore, Delete, DeleteScope, ServiceManager. |
| `README.md` | End-user documentation. |
| `CLAUDE.md` | This file. |

At runtime the script also creates: `dhcp_utility.log`, `dhcp_config.json`, and a `Backups\` folder tree — all relative to the script directory.

---

## Non-Negotiable Rules

These rules exist because earlier versions of this code caused real runtime crashes.
**Do not break them under any circumstances.**

### 1. ASCII encoding — no BOM, no non-ASCII bytes

Both files must be pure 7-bit ASCII. No UTF-8 BOM, no Unicode characters, no smart quotes, no em-dashes.

**Why:** The scripts run on Windows Server 2012 where the default console code page is not UTF-8. A BOM or non-ASCII byte in the `.ps1` causes a parse error before any code runs. A BOM in the `.cmd` causes the first line to be mis-parsed.

**How to verify:**

```python
with open('DHCP_Utility.ps1', 'rb') as f:
    raw = f.read()
assert raw[:3] != b'\xef\xbb\xbf', "BOM found"
assert all(b < 128 for b in raw), "non-ASCII bytes found"
```

Run this check after every edit. Never save with BOM.

---

### 2. Wrap path variables in `${}` inside double-quoted strings

Any variable that may contain a Windows path (drive letter + colon + backslash, e.g. `C:\Users\...`) **must** be written as `${VarName}` inside double-quoted strings.

**Why:** PowerShell's string interpolation parser sees `$Foo:` and interprets the colon as a scope qualifier (`$scope:variable`), then tries to find a variable named after the drive letter. This is a parse-time error — the script refuses to start.

**Bad (crashes at parse time):**
```powershell
Write-Log "File saved: $backupFile"
Write-Log "Error deleting $target: $_"
```

**Good:**
```powershell
Write-Log "File saved: ${backupFile}"
Write-Log "Error deleting ${target}: $_"
```

**Variables in this project that require `${}`:**

```
$BackupsRoot   $ScriptDir     $LogFile       $ConfigFile
$TempExport    $backupFile    $backupCopy    $hashSidecar
$backupFolder  $restorePath   $delBak        $delSC
$target        $sidecar       $ScopeId
```

**Scan command to find violations before committing:**

```python
import re

with open('DHCP_Utility.ps1', 'r', encoding='ascii') as f:
    lines = f.readlines()

danger = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*):')
for i, line in enumerate(lines, 1):
    if '"' not in line:
        continue
    parts = line.split('"')
    for idx in range(1, len(parts), 2):   # inside double-quotes only
        for m in danger.finditer(parts[idx]):
            before = parts[idx][max(0, m.start()-1):m.start()]
            if before not in ('{', '('):
                print(f"Line {i}: {m.group(0)!r} -- needs ${{{m.group(1)}}}")
```

---

### 3. Never use `[Console]::OutputEncoding`

Do not add `[Console]::OutputEncoding = ...` anywhere in the script.

**Why:** This line throws `"The handle is invalid"` when PowerShell is launched from CMD via `-File`, killing the script before a single line of user-visible output is produced. Logging already uses `-Encoding ASCII` on `Add-Content` — that is sufficient.

---

### 4. The `Select-FromList` helper returns -1 for cancel

`Select-FromList` returns `($num - 1)` for valid selections and **`-1`** when the user types `0`.

Every call site **must** check for `-1` before using the result as an array index. Using `-1` as an array index returns the last element of the array — a silent wrong result, not an error.

**Required pattern at every call site:**

```powershell
$idx = Select-FromList '  Select a file' $files.Count
if ($idx -eq -1) {
    Out-Banner '[i] Cancelled.' Cyan
    Write-Log 'Operation cancelled.'
    Write-Host ''
    Read-Host '  Press Enter to return to menu'
    return
}
$selectedFile = $files[$idx]
```

---

### 5. The `Read-NonEmptyInput` helper returns `$null` for cancel

`Read-NonEmptyInput` returns the typed string for valid input and **`$null`** when the user types `0` or presses Enter on a blank line.

Every call site **must** check for `$null` before using the result.

**Required pattern:**

```powershell
$serverName = Read-NonEmptyInput '  Server / Location name'
if ($null -eq $serverName) {
    Out-Banner '[i] Cancelled.' Cyan
    Write-Log 'Operation cancelled.'
    Write-Host ''
    Read-Host '  Press Enter to return to menu'
    return
}
```

---

### 6. Use `Get-Service` instead of `sc.exe` for DHCP service checks

`$null = sc.exe query DHCPServer 2>&1` swallows `$LASTEXITCODE`. Use the existing `Test-DhcpService` helper, which calls `Get-Service -Name DHCPServer -ErrorAction SilentlyContinue`.

---

### 7. No `-NonInteractive` on the PowerShell call in the launcher

The launcher calls PowerShell with `-File`. Do **not** add `-NonInteractive` — `Read-Host` prompts in the `.ps1` require an interactive console. Adding `-NonInteractive` makes all `Read-Host` calls throw immediately.

---

## Architecture

### Execution flow

```
User double-clicks DHCP_Launcher.cmd
    → CMD checks for admin rights (net session)
    → If not elevated: re-launches self via PowerShell Start-Process -Verb RunAs
    → Elevated CMD shows 6-option menu
    → User picks option
    → CMD calls: powershell -NoProfile -ExecutionPolicy Bypass -File DHCP_Utility.ps1 -Mode <X>
    → PS1 runs selected function, returns to CMD menu on exit
```

### Modes / Entry point

```powershell
switch ($Mode) {
    'Backup'         { Invoke-Backup         }
    'Restore'        { Invoke-Restore        }
    'Delete'         { Invoke-Delete         }
    'DeleteScope'    { Invoke-DeleteScope    }
    'ServiceManager' { Invoke-ServiceManager }
    'Menu'           { Show-Menu             }   # standalone PS1 usage
}
```

### Path resolution

```powershell
$ScriptDir   = $PSScriptRoot          # or fallback to $MyInvocation / Get-Location
$BackupsRoot = Join-Path $ScriptDir 'Backups'
$LogFile     = Join-Path $ScriptDir 'dhcp_utility.log'
$ConfigFile  = Join-Path $ScriptDir 'dhcp_config.json'
$TempExport  = Join-Path $env:TEMP   'dhcp_export_temp.txt'   # never on USB
```

`$TempExport` deliberately goes to the local machine's `%TEMP%`, not the USB drive. `netsh` export to a USB path can fail or be very slow.

### Helper functions reference

| Function | Returns | Notes |
|---|---|---|
| `Write-Log` | void | Appends timestamped ASCII line to `$LogFile` |
| `Out-Header` | void | Cyan double-line banner |
| `Out-Banner` | void | Single coloured status line |
| `Get-SHA256` | string (hex) | PS4+ uses `Get-FileHash`; PS3 uses .NET `SHA256Managed` |
| `Save-HashSidecar` | void | Writes `.sha256` JSON with ASCII encoding |
| `Test-HashSidecar` | hashtable `{Ok, Reason, StoredHash, LiveHash}` | Re-hashes `.txt` and compares to sidecar |
| `Get-SafeName` | string | Strips illegal folder-name chars, collapses underscores |
| `Write-OSVersion` | void | Logs OS caption, build, PS version to log file |
| `Initialize-Config` | void | Creates `dhcp_config.json` if absent |
| `Save-BackupConfig` | void | Writes backup metadata to config |
| `Save-RestoreConfig` | void | Writes restore metadata to config |
| `Read-NonEmptyInput` | string or `$null` | `$null` = user cancelled (typed 0 or blank) |
| `Select-FromList` | int (0-based) or `-1` | `-1` = user cancelled (typed 0) |
| `Test-DhcpService` | bool | True if DHCPServer service exists |
| `Get-DhcpScopes` | array of PSCustomObject | Module preferred, netsh fallback |
| `Remove-DhcpScope` | bool | True on success; module preferred, netsh fallback |

---

## PowerShell Version Compatibility

The script targets **PowerShell 3.0** (ships with Windows Server 2012) as the minimum. Every feature used must exist in PS 3.0.

| Feature needed | PS 3.0 safe? | Notes |
|---|---|---|
| `$PSScriptRoot` | Yes | Empty string in some edge cases — use the fallback chain |
| `Get-FileHash` | **No** (PS 4.0+) | Use `Get-SHA256` helper which has a .NET fallback |
| `ConvertFrom-Json` | Yes | Read sidecar with `[System.IO.File]::ReadAllText` + ASCII encoding first |
| `ConvertTo-Json` | Yes | Available but avoid for config writes — use string concatenation to control encoding |
| `[ordered]` hashtable | Yes (PS 3.0+) | Safe to use |
| `Get-DhcpServerv4Scope` | **No** (requires DhcpServer module) | Always check `Get-Module -ListAvailable DhcpServer` first |
| `Remove-DhcpServerv4Scope` | **No** (requires DhcpServer module) | Same — always fall back to netsh |
| `Start-Service` / `Stop-Service` | Yes | |
| `Get-Service` | Yes | |

**Do not use:**
- `#Requires -Version X` — this causes a non-descriptive red error instead of a helpful message
- `Get-FileHash` directly — always go through `Get-SHA256`
- `Get-DhcpServerv4Scope` directly — always go through `Get-DhcpScopes`

---

## JSON / Config Files

Config and sidecar JSON is written with `[System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::ASCII)` — **never** with `Out-File`, `Set-Content`, or `Add-Content` for these files.

**Why:** `Out-File` defaults to UTF-16LE. `Set-Content` and `Add-Content` add a BOM in some PS versions. `WriteAllText` with the ASCII encoding object is the only reliable way to produce a BOM-free ASCII file.

JSON is built by string concatenation, not `ConvertTo-Json`, to guarantee exact formatting and ASCII-only output:

```powershell
$json = "{`r`n" +
        "  `"key`": `"value`"`r`n" +
        "}"
[System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::ASCII)
```

---

## Scope Discovery / Deletion Compatibility

`Get-DhcpScopes` and `Remove-DhcpScope` use a two-tier approach. Always maintain both tiers:

**Tier 1 — DhcpServer PS module (WS2012 R2+):**
- Check `Get-Module -ListAvailable -Name DhcpServer`
- Import if found
- Use `Get-DhcpServerv4Scope` / `Get-DhcpServerv6Scope`
- Use `Remove-DhcpServerv4Scope -Force` / `Remove-DhcpServerv6Scope -Force`

**Tier 2 — netsh (WS2012 fallback, IPv4 only):**
- `netsh dhcp server show scope` for listing
- `netsh dhcp server scope <IP> delete` for deletion
- Parse output with regex; do not assume fixed column widths

---

## Cancel Behaviour Contract

Every interactive operation must be cancellable. The contract is:

- `Select-FromList` always appends `(0=Cancel)` to its prompt and returns `-1` on `0`.
- `Read-NonEmptyInput` always appends `(0=Cancel)` to its prompt and returns `$null` on `0` or blank Enter.
- Every call site checks for the cancel signal **immediately** after the call.
- On cancel: print `[i] <Operation> cancelled.` in Cyan, log it, `Read-Host '  Press Enter...'`, `return`.
- Destructive confirmation prompts (`YES`, `DELETE`, `OVERRIDE`, `STOP`) are separate — anything other than the exact required word is treated as cancel without requiring a separate `0`.

---

## Adding a New Operation

When adding a new top-level operation:

1. Write a function named `Invoke-<OperationName>`.
2. Add the mode name to the `ValidateSet` in the `param()` block.
3. Add a `case` to the `switch ($Mode)` entry point.
4. Add a menu entry in `Show-Menu` and increment the valid range in `Read-Host`.
5. Add a launcher block in `DHCP_Launcher.cmd` (`:RUN_<OPERATIONNAME>` label + `goto :MAIN_MENU`).
6. Add the menu item to the CMD `echo` block and the `if "!CHOICE!"...` dispatch.
7. Update `README.md`.

---

## Testing Checklist

Before delivering any change, verify:

- [ ] `python3 -c "raw=open('DHCP_Utility.ps1','rb').read(); assert raw[:3]!=b'\xef\xbb\xbf'; assert all(b<128 for b in raw)"` passes
- [ ] Same check passes for `DHCP_Launcher.cmd`
- [ ] The `$var:` colon-danger scan (see Rule 2) finds zero violations
- [ ] Every new `Select-FromList` call has a `-eq -1` guard
- [ ] Every new `Read-NonEmptyInput` call has a `$null -eq` guard
- [ ] New code uses `${VarName}` for all path variables inside double-quoted strings
- [ ] No `Get-FileHash`, `Get-DhcpServerv4Scope`, or `Remove-DhcpServerv4Scope` called directly (must go through helpers)
- [ ] Version string in header comment, `Out-Header` calls, and menu banner are consistent
