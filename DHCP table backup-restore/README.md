# DHCP Backup & Restore Utility

A portable, self-elevating Windows utility for backing up, restoring, and managing DHCP server configurations. Designed to run from a USB drive on any Windows Server 2012 or newer machine — no installation required.

---

## Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [File Layout](#file-layout)
- [Quick Start](#quick-start)
- [Menu Options](#menu-options)
  - [1. Backup](#1-backup)
  - [2. Restore](#2-restore)
  - [3. Delete Backups](#3-delete-backups)
  - [4. Delete Scope](#4-delete-scope)
  - [5. DHCP Service](#5-dhcp-service)
- [Backup File Structure](#backup-file-structure)
- [Hash Verification](#hash-verification)
- [Cancelling Operations](#cancelling-operations)
- [Log File](#log-file)
- [Portability](#portability)
- [Compatibility Notes](#compatibility-notes)
- [Security Considerations](#security-considerations)

---

## Overview

This tool wraps the built-in `netsh dhcp` commands in a guided, menu-driven interface. It handles:

- Exporting the full DHCP configuration (all scopes, leases, reservations, and options) to a timestamped file
- Verifying backup integrity with SHA-256 hashes stored in a sidecar file
- Restoring a backup with optional pre-deletion of existing scopes (required for a clean restore)
- Deleting individual DHCP scopes directly from the live server
- Starting, stopping, and restarting the DHCP Server service

All paths are relative to the USB drive, so the tool works regardless of which drive letter Windows assigns to the drive.

---

## Requirements

| Requirement | Minimum |
|---|---|
| Windows Server | 2012 (Server Core and Desktop Experience) |
| Windows Client | Windows 8 (for testing only — DHCP Server role is server-only) |
| PowerShell | 3.0+ (ships with Windows Server 2012) |
| Privileges | Local Administrator (the launcher self-elevates via UAC) |
| DHCP Server role | Must be installed on the target machine |

---

## File Layout

### On the USB drive

```
DHCP_Launcher.cmd       ← Run this to start the utility
DHCP_Utility.ps1        ← All logic (do not move separately from the launcher)
README.md               ← This file
dhcp_utility.log        ← Created automatically on first run
dhcp_config.json        ← Created automatically on first run
Backups\                ← Created automatically on first backup
    DC01\
        dhcp_DC01_20260301_143022.txt       Primary export
        dhcp_DC01_20260301_143022.bak       Redundant copy
        dhcp_DC01_20260301_143022.sha256    Hash sidecar (JSON)
    HQ-DHCP\
        dhcp_HQ-DHCP_20260228_091500.txt
        ...
```

### Per backup set (three files)

| File | Purpose |
|---|---|
| `.txt` | The DHCP export produced by `netsh dhcp server export`. This is the file used for restore. |
| `.bak` | Byte-for-byte redundant copy of the `.txt` file. |
| `.sha256` | JSON sidecar containing the SHA-256 hash of both the `.txt` and `.bak` files, the server name, and the backup timestamp. |

---

## Quick Start

1. Copy `DHCP_Launcher.cmd` and `DHCP_Utility.ps1` to the same folder on your USB drive.
2. Plug the USB drive into the Windows Server machine.
3. Double-click `DHCP_Launcher.cmd`.
4. Accept the UAC prompt when it appears.
5. Choose an option from the menu.

> **Do not run `DHCP_Utility.ps1` by right-clicking "Run with PowerShell"** — use the launcher so that UAC elevation and the working directory are set correctly. You can run the `.ps1` directly from an already-elevated PowerShell window if needed.

---

## Menu Options

```
  ==================================================

         DHCP Backup & Restore Utility

  ==================================================

    [1]  Backup          --  Export and save DHCP table
    [2]  Restore         --  Import DHCP table from backup
    [3]  Delete Backups  --  Remove old backup files
    [4]  Delete Scope    --  Remove existing DHCP scope(s)
    [5]  DHCP Service    --  Start / Stop / Restart DHCP Server
    [6]  Exit
```

---

### 1. Backup

Exports the full DHCP configuration from the local server and saves it under `Backups\<LocationName>\`.

**Steps the utility performs:**

1. Checks that the DHCP Server service is installed and present.
2. Shows a numbered list of **existing backup locations** (server/site names used in previous backups). You can add a new backup to an existing location or create a new one.
3. Runs `netsh dhcp server export` to a local temp file (`%TEMP%\dhcp_export_temp.txt`), then copies it to the USB.
4. Computes the SHA-256 hash of the source, the primary `.txt`, and the `.bak` copy, and compares all three to verify the copy was not corrupted in transit.
5. Saves a `.sha256` sidecar file alongside the backup.
6. Removes the temp file.

**To cancel** at any prompt, enter `0`.

---

### 2. Restore

Imports a saved DHCP configuration back onto the local server.

**Steps the utility performs:**

1. Lists available backup locations and lets you choose one.
2. Lists backup files for the chosen location, newest first, with hash sidecar status shown.
3. **Verifies the SHA-256 hash** of the selected file against its sidecar before doing anything destructive. If the hash does not match, you are warned and must type `OVERRIDE` in capitals to proceed.
4. Asks for final confirmation — you must type `YES` in capitals.
5. **Pre-restore scope cleanup** — queries the live DHCP server for existing scopes and offers to delete them before import. This is strongly recommended because `netsh dhcp server import` *merges* rather than replaces, so existing scopes that are not in the backup file remain after the import and can cause conflicts.
6. Runs `netsh dhcp server import`.
7. Restarts the DHCP Server service automatically. If the restart fails, opens `services.msc` so you can restart it manually.

> **This operation modifies the live DHCP configuration and cannot be undone.** Always take a fresh backup of the current state before restoring from an older file.

**To cancel** at the location picker, file picker, or scope-cleanup step, enter `0`.

---

### 3. Delete Backups

Removes old backup files from the USB drive to free space.

**Two sub-modes:**

- **Delete a specific backup set** — removes the `.txt`, `.bak`, and `.sha256` files for one backup. If the location folder becomes empty, offers to remove the folder too.
- **Delete ALL backups for a location** — removes the entire folder and every file inside it.

Both modes require typing `DELETE` in capitals to confirm. All deletions are logged.

**To cancel** at the location picker, mode picker, or file picker, enter `0`.

---

### 4. Delete Scope

Queries the live DHCP server for all configured scopes (IPv4 and IPv6) and lets you remove them.

**Two sub-modes:**

- **Delete a specific scope** — shows the scope ID, subnet mask, state, and name. Requires typing `DELETE` to confirm.
- **Delete ALL scopes** — lists every scope that will be removed. Requires typing `DELETE` to confirm.

Uses the `DhcpServer` PowerShell module (Windows Server 2012 R2+) when available for the most reliable results. Falls back to parsing `netsh dhcp server show scope` output on plain Windows Server 2012.

> This feature is also integrated into the **Restore** flow as a pre-restore step.

**To cancel** at any picker, enter `0`.

---

### 5. DHCP Service

An interactive status panel for the DHCP Server service.

Shows the current service state (green = Running, red = Stopped, yellow = transitional) on every loop. Actions available:

| Option | Action |
|---|---|
| `[1]` | Start the service |
| `[2]` | Stop the service (requires typing `STOP` to confirm) |
| `[3]` | Restart the service (stop + 3-second wait + start) |
| `[4]` | Refresh the status display |
| `[5]` | Return to main menu |

**To return to the main menu** without taking an action, enter `0` or choose `[5]`.

---

## Backup File Structure

The `.sha256` sidecar is plain ASCII JSON:

```json
{
  "server":    "DC01",
  "timestamp": "20260301_143022",
  "created":   "2026-03-01 14:30:22",
  "txt_hash":  "A3F9E2...",
  "bak_hash":  "A3F9E2..."
}
```

`txt_hash` and `bak_hash` should always match each other — they are separate copies of the same file. If they differ, it indicates a write error during the backup.

---

## Hash Verification

Every backup session computes SHA-256 for three files and compares them:

```
Source file (temp, local disk)
    ↓  must match
Primary .txt  (USB drive)
    ↓  must match
Redundant .bak  (USB drive)
```

At restore time, the `.txt` file is re-hashed and compared against `txt_hash` in the sidecar. A mismatch means the file was modified or corrupted after it was backed up.

**On Windows Server 2012 R2+:** uses `Get-FileHash` (built-in PowerShell cmdlet).  
**On Windows Server 2012 (PS 3.0):** falls back to `System.Security.Cryptography.SHA256Managed` (.NET).

---

## Cancelling Operations

Every interactive prompt accepts `0` as a universal cancel signal. Typing `0` at any selection list or name-entry prompt will:

1. Print a `[i] … cancelled.` message in cyan.
2. Log the cancellation to `dhcp_utility.log`.
3. Return immediately to the main menu.

Destructive confirmation prompts (`YES`, `DELETE`, `OVERRIDE`, `STOP`) work differently — anything other than the exact word returns you to the menu without doing anything.

---

## Log File

`dhcp_utility.log` is created in the same folder as the scripts on first run. Every session appends to it — it is never overwritten.

Each line is timestamped:

```
[2026-03-01 14:30:18] Backup session start
[2026-03-01 14:30:18] Script dir   : E:\DHCP-Tool
[2026-03-01 14:30:18] OS Caption   : Windows Server 2019 Standard
[2026-03-01 14:30:18] PS Version   : 5.1.17763.1
[2026-03-01 14:30:19] DHCP Server service confirmed.
[2026-03-01 14:30:19] Backup location: existing folder 'DC01' selected by user.
[2026-03-01 14:30:22] Export OK. Size: 48392 bytes
[2026-03-01 14:30:23] Integrity check PASSED.
[2026-03-01 14:30:23] Hash sidecar saved : E:\DHCP-Tool\Backups\DC01\dhcp_DC01_20260301_143022.sha256
[2026-03-01 14:30:23] --- Backup COMPLETED for: DC01 ---
```

The log records the OS version, PowerShell version, all file paths, netsh output and exit codes, hash values, and any errors.

---

## Portability

All file paths are resolved relative to the location of `DHCP_Utility.ps1` using `$PSScriptRoot`. This means:

- The USB drive can be assigned any drive letter (E:, F:, G:, etc.).
- The folder can be renamed or moved.
- `dhcp_config.json` stores paths as relative strings (e.g. `Backups\DC01\...`) so that stored metadata remains valid after the drive letter changes.
- The temp export file always goes to `%TEMP%` on the local machine, never to the USB drive, to avoid write-speed issues and potential USB read-only states during export.

**The only requirement is that `DHCP_Launcher.cmd` and `DHCP_Utility.ps1` remain in the same folder.**

---

## Compatibility Notes

| Feature | WS 2012 (PS 3.0) | WS 2012 R2+ (PS 4.0+) |
|---|---|---|
| SHA-256 hashing | .NET `SHA256Managed` fallback | `Get-FileHash` |
| Scope enumeration | `netsh` output parsing | `DhcpServer` PS module |
| Scope deletion | `netsh dhcp server scope … delete` | `Remove-DhcpServerv4Scope -Force` |
| JSON config | `ConvertTo-Json` / manual string build | Same |
| All other features | Full support | Full support |

---

## Security Considerations

- **Administrator rights are required.** The launcher requests elevation via UAC on startup. No second prompt appears for subsequent operations in the same session.
- **Backup files contain the full DHCP database** including all lease history, reservations, and DHCP options. Treat them with the same care as any network configuration export.
- **The SHA-256 sidecar provides integrity checking, not authentication.** It will detect accidental corruption or unintended modification, but not a deliberate attack by someone who also has write access to the USB drive.
- **ExecutionPolicy is bypassed** with `-ExecutionPolicy Bypass` in the launcher call. This is intentional for a portable tool that cannot be code-signed. Review the `.ps1` source before running it on a production server.
