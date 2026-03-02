# Sync SocialFeed & TextEffects — Backup/Restore Script

A self-elevating, self-healing PowerShell backup and restore tool for Brunswick Sync scoring system files. Keeps versioned backups of `SocialFeed.txt` and `TextEffects.txt` with an interactive menu, full activity logging, and automatic cleanup of old versions.

---

## Package Contents

| File | Description |
|---|---|
| `Launch.cmd` | Double-click entry point. Handles elevation, PS detection, and unblocking. |
| `SyncBackupRestore.ps1` | Main PowerShell script — all backup, restore, and logging logic. |
| `SyncBackupRestore.json` | Configuration file. Auto-created with defaults if missing. |
| `SyncBackupRestore.log` | Activity log. Created automatically on first run. |
| `Backup\` | Versioned backup folder. Created automatically on first backup. |

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Windows Server 2016 / 2019 / 2022, Windows 10 / 11 |
| PowerShell | 3.0 or newer (Windows PowerShell or PowerShell 7+) |
| Privileges | Administrator (script self-elevates via UAC) |
| Disk space | Minimal — only stores plain text files |

---

## Quick Start

1. Place all files in the same folder (USB stick, Desktop, network share, etc.)
2. **Right-click** `Launch.cmd` → **Run as administrator**
   *(or just double-click — the launcher will request UAC elevation automatically)*
3. Follow the on-screen menu

---

## How It Works

### Launcher (`Launch.cmd`)

The CMD launcher runs first and handles the environment before PowerShell starts:

- **Detects PowerShell** — prefers `pwsh.exe` (PowerShell 7+), falls back to `powershell.exe` (Windows PowerShell 5/3 — standard on Server 2016)
- **Self-unblocks script files** — strips the `Zone.Identifier` NTFS alternate data stream from all package files. This removes the *"Unknown publisher"* UAC warning and the *"running scripts is disabled"* ExecutionPolicy block that appear on files downloaded from the internet or copied from a network share
- **Self-elevates via UAC** — if not already running as Administrator, relaunches itself elevated using `Start-Process -Verb RunAs`. Uses environment variable path passing (`$env:SELF`) to handle spaces in the script path correctly. If UAC is declined or disabled, offers to continue unelevated with a warning
- **Passes `ScriptRoot`** explicitly to the `.ps1` so backup and log paths resolve correctly regardless of the working directory

### PowerShell Script (`SyncBackupRestore.ps1`)

On startup the script:

1. Forces **InvariantCulture** — neutralises regional setting differences (decimal separators, date parsing) across different Windows locales
2. **Self-unblocks** companion files (secondary safety net when running the `.ps1` directly without the launcher)
3. **Self-elevates** if not already Administrator (covers running directly from ISE, VS Code, right-click → Run with PowerShell, etc.)
4. Loads or creates the **JSON config**
5. Scans for existing backups and displays a **status summary** with count and timestamps
6. Presents the **interactive menu**

---

## Backup Process

- Copies `SocialFeed.txt` and `TextEffects.txt` from the configured source folder to a timestamped subfolder under `.\Backup\`
- Subfolder names use the format `dd.MM.yyyy-HH.mm` (e.g. `27.05.2025-14.30`)
- If a source file is missing, the script warns and offers to switch to Restore mode
- After each backup, automatically **prunes old versions** to stay within `MaxBackupVersions` (default: 3), removing oldest first
- All activity written to `SyncBackupRestore.log`

### Backup folder structure

```
Backup\
    27.05.2025-14.30\
        SocialFeed.txt
        TextEffects.txt
    27.05.2025-09.15\
        SocialFeed.txt
        TextEffects.txt
    26.05.2025-16.00\
        SocialFeed.txt
        TextEffects.txt
```

---

## Restore Process

1. Lists all available backup versions with date, time, and which files are present
2. Prompts for a version number to restore
3. Shows a **clear warning** that destination files will be overwritten with no undo
4. Requires explicit confirmation before proceeding
5. Gracefully handles **read-only files** — strips the read-only attribute before overwriting, restores the file, then leaves attribute management to the OS
6. Reports per-file success or failure and writes results to the log

---

## Configuration (`SyncBackupRestore.json`)

Edit this file to change script behaviour without touching the `.ps1`. The file is auto-created with defaults if deleted.

```json
{
    "SourceFolder": "C:\\Program Files (x86)\\Brunswick\\Sync\\SyncInstall\\Content\\ScoringMaterials",
    "FilesToBackup": [
        "SocialFeed.txt",
        "TextEffects.txt"
    ],
    "MaxBackupVersions": 3,
    "BackupFolderName": "Backup",
    "LogFileName": "SyncBackupRestore.log"
}
```

| Setting | Description |
|---|---|
| `SourceFolder` | Full path to the folder containing the Brunswick Sync files |
| `FilesToBackup` | Array of file names to back up and restore |
| `MaxBackupVersions` | How many backup versions to keep. Oldest removed automatically. Minimum recommended: 3 |
| `BackupFolderName` | Name of the backup subfolder (relative to script location) |
| `LogFileName` | Name of the log file (relative to script location) |

---

## Resilience Features

| Feature | Detail |
|---|---|
| Multi-PS-version safe | Tested on PowerShell 3, 4, 5.1, and 7+. Array returns wrapped in `@()` everywhere to prevent `.Count` failures on older versions |
| Regional setting safe | InvariantCulture forced at thread level — decimal separators, date formats, and string comparisons are locale-independent |
| Pure ASCII source | All script files are plain ASCII with UTF-8 BOM on the `.ps1`. Eliminates the Windows-1252 / UTF-8 byte misreading bug that causes cascading parser errors on systems with non-English locales |
| Path-with-spaces safe | All path handling uses `-LiteralPath` and quoted variables. UAC relaunch uses `$env:` variable passing to avoid CMD expansion breaking paths that contain spaces |
| Self-healing config | Missing or corrupt config file is replaced with defaults automatically |
| Self-healing backup folder | Created automatically if it doesn't exist |
| Zone.Identifier removal | Strips the internet download mark from all script files on first run |
| Missing source files | Detected early with a clear message and offer to restore instead |
| Read-only destination files | Attribute cleared before restore, failure reported if clearing fails |

---

## Troubleshooting

**"Execution policy" or "cannot be loaded" error**
The CMD launcher sets `-ExecutionPolicy Bypass` automatically. If running the `.ps1` directly:
```powershell
powershell -ExecutionPolicy Bypass -File SyncBackupRestore.ps1
```

**"Unknown publisher" UAC warning**
The launcher automatically strips the `Zone.Identifier` stream on startup. If running the file immediately after download before the launcher has run, right-click the `.ps1` → Properties → tick **Unblock** → OK.

**"Access denied" when restoring**
The session is not elevated. Close and re-run `Launch.cmd` — it will request UAC. Alternatively right-click → Run as administrator.

**Source files not found**
Verify Brunswick Sync is installed and check the `SourceFolder` path in `SyncBackupRestore.json` matches your actual installation path.

**UAC prompt never appears / is disabled**
On some locked-down servers UAC is fully disabled. In that case, log in as the built-in Administrator account directly, or run the script from an account that is a member of the local Administrators group with UAC disabled system-wide.

---

## Log File

All activity is written to `SyncBackupRestore.log` in the script folder. Each entry is timestamped:

```
================================================================
[2025-05-27 14:30:01] [INFO] Script started: Sync SocialFeed and TextEffects Backup/Restore Script v1.1
[2025-05-27 14:30:01] [INFO] Elevated      : Yes
[2025-05-27 14:30:05] [OK]   Backed up: SocialFeed.txt -> Backup\27.05.2025-14.30\SocialFeed.txt (12048 bytes)
[2025-05-27 14:30:05] [OK]   Backed up: TextEffects.txt -> Backup\27.05.2025-14.30\TextEffects.txt (8192 bytes)
[2025-05-27 14:30:05] [OK]   Backup complete: 2 file(s) backed up
[2025-05-27 14:30:05] [INFO] Removed old backup: 24.05.2025-09.00
================================================================
```

---

## Default Source Path

```
C:\Program Files (x86)\Brunswick\Sync\SyncInstall\Content\ScoringMaterials
```

Change this in `SyncBackupRestore.json` if your Brunswick Sync installation is in a non-default location.
