# CLAUDE.md — Guidance for Claude Code

This file provides instructions for Claude Code (claude.ai/code) when working with the
**Sync SocialFeed & TextEffects Backup/Restore Script** project.

---

## Project Overview

A two-file PowerShell backup/restore tool for Brunswick Sync scoring system files.
The entry point is a CMD launcher (`Launch.cmd`) that bootstraps the environment and
then hands off to the main PowerShell script (`SyncBackupRestore.ps1`).

**Target files being backed up:**
- `C:\Program Files (x86)\Brunswick\Sync\SyncInstall\Content\ScoringMaterials\SocialFeed.txt`
- `C:\Program Files (x86)\Brunswick\Sync\SyncInstall\Content\ScoringMaterials\TextEffects.txt`

---

## File Inventory

```
Launch.cmd                  CMD launcher - entry point, handles elevation + unblocking
SyncBackupRestore.ps1       Main PowerShell script - all logic lives here
SyncBackupRestore.json      Config file - auto-created with defaults if missing
SyncBackupRestore.log       Activity log - created on first run (do not edit)
Backup\                     Versioned backup folder - created automatically
    dd.MM.yyyy-HH.mm\       Timestamped subfolders (e.g. 27.05.2025-14.30)
        SocialFeed.txt
        TextEffects.txt
CLAUDE.md                   This file
README.md                   End-user documentation
```

---

## Critical Constraints — Read Before Editing Anything

### 1. Pure ASCII only in both files

**The single most important rule in this project.**

The `.ps1` is read by Windows PowerShell 5.1 on Windows Server 2016. If the file has
no UTF-8 BOM, PS 5.1 reads it using the system ANSI codepage (Windows-1252 on most
Western/EU systems). The UTF-8 encoding of an en-dash (`-`, U+2013) is `0xE2 0x80 0x93`.
Byte `0x93` in Windows-1252 is a **right curly double-quote `"`**. This silently closes
string literals mid-line and causes cascading parser errors that look completely unrelated
to the actual cause.

**Rules:**
- Never use en-dashes (`-`) — use plain ASCII hyphens (`-`)
- Never use em-dashes (`-`) — use plain ASCII hyphens or ` - ` with spaces
- Never use curly/smart quotes (`"` `"` `'` `'`) — use straight `"` and `'`
- Never use ellipsis (`...`) — use three dots `...`
- Never use any Unicode character above U+007F anywhere in either file
- The `.ps1` is saved with a **UTF-8 BOM** (`EF BB BF` as first three bytes) — preserve this

**How to verify before saving:**
```python
content = open('SyncBackupRestore.ps1', encoding='utf-8').read()
bad = [(i+1, j+1, hex(ord(c)), c) for i,l in enumerate(content.splitlines())
       for j,c in enumerate(l) if ord(c) > 127]
print(bad)  # must be empty
```

**How to save the .ps1 correctly (Python):**
```python
with open('SyncBackupRestore.ps1', 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(content)
```
`utf-8-sig` writes the BOM. `newline='\r\n'` ensures Windows CRLF line endings.

**The .cmd must be saved as plain ASCII, no BOM, CRLF:**
```python
with open('Launch.cmd', 'w', encoding='ascii', newline='\r\n') as f:
    f.write(content)
```

---

### 2. Variable-colon rule in PowerShell string interpolation

PowerShell treats `$name:` inside a double-quoted string as a scoped variable reference
(same syntax as `$env:`, `$script:`, `$global:`). If `$name` is followed immediately by
a colon (e.g. in a log message like `"Failed: $f: $_"`), the parser throws a
`Variable reference is not valid` error.

**Rule:** Any variable that is immediately followed by `:` inside a double-quoted string
must be wrapped in `${}`:

```powershell
# WRONG - causes parser error
Write-Log "Failed to back up $f: $_"

# CORRECT
Write-Log "Failed to back up ${f}: $_"
```

---

### 3. Always wrap collection results in `@()`

This project targets PowerShell 3.0+. On PS 3 and 4, a function that returns a single
object does **not** auto-wrap it in an array. Calling `.Count` on a bare object throws:
`The property 'Count' cannot be found on this object.`

**Rule:** Every call to `Get-BackupList` and every pipeline that feeds into a `.Count`
check or `foreach` must be wrapped in `@()`:

```powershell
# WRONG
$backups = Get-BackupList -Config $Config
if ($backups.Count -eq 0) { ... }

# CORRECT
$backups = @(Get-BackupList -Config $Config)
if ($backups.Count -eq 0) { ... }
```

Also apply to:
- `$toDelete = @($all | Select-Object -Skip $max)`
- `foreach ($f in @($chosen.Files))`
- `(@($b.Files)) -join ", "`

---

### 4. Path handling — always use `-LiteralPath`

Paths in this project can contain spaces, brackets, and non-ASCII characters (user names
like `JanisKalnins`, folder names like `SocialFeed Backup-Restore`). Always use
`-LiteralPath` instead of `-Path` for file operations. `-Path` interprets wildcards and
brackets which breaks silently on unusual paths.

```powershell
# WRONG
Copy-Item -Path $srcFile -Destination $destFile

# CORRECT
Copy-Item -LiteralPath $srcFile -Destination $destFile
```

---

### 5. UAC relaunch quoting in the CMD launcher

The CMD launcher must pass the script's own path to an elevated process. CMD expands
`%VARIABLE%` inside PowerShell `-Command` strings before PowerShell sees them — so
paths with spaces break the argument parsing.

**The established pattern** — use `$env:SELF` (read by PowerShell from the environment,
not expanded by CMD) and `[char]34` (produces `"` inside PowerShell without CMD
interference):

```batch
:: Set the path as an environment variable
set "SELF=%~f0"

:: Reference it in PowerShell via $env:SELF, use [char]34 for inner quotes
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "$a='/C set ELEVATED_RELAUNCH=1 && ' + [char]34 + $env:SELF + [char]34; Start-Process $env:ComSpec -ArgumentList $a -Verb RunAs -Wait"
```

Do not replace this pattern with inline `%SELF%` expansion — it will break for any path
containing spaces.

---

### 6. `$LogFile` may be undefined during early init

`Write-Log` is defined before `$LogFile` is set (because the Logging region must come
before Self-Unblock which calls `Write-Log`). The function guards against this:

```powershell
if (-not [string]::IsNullOrEmpty($LogFile)) {
    Add-Content -Path $LogFile ...
}
```

Do not remove this guard. Do not move the Constants region above the Logging region —
the current order exists deliberately: `Logging` → `Self-Unblock` → `Self-Elevation` →
`Constants`.

---

## Region Order in SyncBackupRestore.ps1

The regions must stay in this exact order — several depend on earlier ones being
initialised:

```
1.  Initialization & Culture Safety   <- sets $ScriptRoot, forces InvariantCulture
2.  Logging                           <- defines Write-Log (used by region 3)
3.  Self-Unblock                      <- calls Write-Log; $LogFile not yet set (guarded)
4.  Self-Elevation                    <- calls Test-IsAdmin; may exit/relaunch
5.  Constants & Configuration         <- sets $LogFile, $BackupRoot, $ConfigFile
6.  Console Helpers                   <- Write-Info, Write-Warn, etc.
7.  Configuration Management          <- Load-Config
8.  Backup Discovery                  <- Get-BackupList
9.  Status Display                    <- Show-BackupStatus
10. Backup Process                    <- Invoke-Backup, Invoke-PruneOldBackups
11. Restore Process                   <- Invoke-Restore
12. Main Entry Point                  <- Main function + entry call
```

---

## Coding Conventions

### PowerShell

- **Indentation:** 4 spaces (no tabs)
- **Braces:** opening brace on same line as statement
- **Region markers:** use the established `# ===...=== / # REGION: Name` banner style
- **User output:** always use the console helper functions, never `Write-Host` directly
  in business logic:
  - `Write-Info`    — informational, cyan `[i]`
  - `Write-Success` — success, green `[OK]`
  - `Write-Warn`    — warning, yellow `[!]`
  - `Write-Err`     — error, red `[X]`
  - `Write-Detail`  — secondary detail, gray (indented)
  - `Write-Section` — section header, yellow `-- Name --`
- **Logging:** every significant action must have a matching `Write-Log` call
- **Log levels:** `INFO` (default), `OK` (success), `WARN` (non-fatal), `ERROR` (fatal/failed)
- **Error handling:** use `try/catch` around all file I/O; log the error; do not let a
  single file failure abort a multi-file loop — increment a counter and continue
- **Date format for backup folders:** `"dd.MM.yyyy-HH.mm"` stored in `$FOLDER_DATE_FORMAT`
  — use this constant, never a hardcoded format string
- **Config access:** use `$Config["Key"]` bracket notation, not `$Config.Key` dot notation,
  because the config is an ordered hashtable and dot notation is unreliable after
  `ConvertFrom-Json` returns a PSCustomObject that gets converted

### CMD

- **Indentation:** 4 spaces
- **Comments:** `::` prefix (not `REM`)
- **Quoting:** always quote variable expansions: `"%VAR%"` not `%VAR%`
- **Errorlevel checks:** always check immediately after the command that sets it;
  delayed expansion can cause issues with `!errorlevel!` in some contexts — prefer
  `set "X=%errorlevel%"` then check `%X%`
- **Labels:** lowercase with colon prefix, e.g. `:ps_found`, `:already_elevated`

---

## Adding a New Feature — Checklist

When adding new functionality to `SyncBackupRestore.ps1`:

- [ ] All strings are pure ASCII (no Unicode > U+007F)
- [ ] Variables followed by `:` in double-quoted strings use `${}` delimiter
- [ ] Any function returning a collection is wrapped in `@()` at the call site
- [ ] All file operations use `-LiteralPath`
- [ ] User-facing output uses the console helper functions (`Write-Info` etc.)
- [ ] Each significant action has a `Write-Log` call
- [ ] File I/O is in `try/catch` blocks
- [ ] New functions are placed in the correct region, or a new region is added in the right order
- [ ] `$SCRIPT_VERSION` is incremented (format: `"major.minor"`)
- [ ] README.md is updated if the feature changes user-visible behaviour

---

## Common Error Signatures and Their Causes

| Error message | Root cause | Fix |
|---|---|---|
| `Variable reference is not valid. ':' was not followed by a valid variable name` | `$varname:` inside string | Wrap as `${varname}:` |
| `The property 'Count' cannot be found on this object` | Single-item return not wrapped in `@()` | Wrap `Get-BackupList` call in `@(...)` |
| `Unexpected token ... Missing closing ')'` (cascading) | Non-ASCII character in file (en-dash misread as `"`) | Run ASCII scan, replace all U+2013/U+2014 with `-` |
| `A parameter cannot be found that matches parameter name 'xxx'` | Value starting with `-` parsed as parameter | Enclose in quotes or use named parameter |
| `Cannot open WinRM service` / `Access is denied` on Start-Service | PowerShell session is not elevated (Medium IL) | Run as Administrator |
| `WinRM firewall exception will not work ... network ... set to Public` | Network profile is Public | `Set-NetConnectionProfile` or `Enable-PSRemoting -Force -SkipNetworkProfileCheck` |
| `[FATAL] An unexpected error occurred: The property 'Count'...` | PS 3/4 single-item array unwrapping | See constraint #3 above |

---

## Testing Without a Brunswick Sync Installation

To test the script without the actual target path existing:

1. Edit `SyncBackupRestore.json` and point `SourceFolder` at any folder containing
   two text files renamed to `SocialFeed.txt` and `TextEffects.txt`
2. Run through Backup → verify `Backup\dd.MM.yyyy-HH.mm\` folder is created
3. Delete the source files, run Restore → verify they are restored
4. Run Backup 4+ times → verify only the 3 newest backups are kept

The script itself will inform you if the source folder is missing and offer to restore —
this is expected and intentional behaviour.

---

## Version History Reference

| Version | Key changes |
|---|---|
| 1.0 | Initial release — backup, restore, pruning, logging, config |
| 1.1 | Self-elevation (UAC), self-unblock (Zone.Identifier), PS3/4 array guards, ASCII-only source, UTF-8 BOM, variable-colon fixes |
