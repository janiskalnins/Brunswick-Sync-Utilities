# Brunswick Display Controller Reset Utility

A two-file PowerShell toolkit for resetting Brunswick Display Controllers to the
**Unknown Configuration** screen. Designed for field technicians running the
procedure from a shared network drive.

---

## Files

| File | Purpose |
|------|---------|
| `RunReset.cmd` | Double-click launcher. Handles elevation and SmartScreen. Always run this file -- never run the `.ps1` directly. |
| `DisplayController-Reset.ps1` | Main script. All logic lives here. |
| `DisplayController_Reset_Log.csv` | Created automatically on first run in the same folder. Audit log of every reset performed. |

Both files must be kept in the **same folder** (local or network share).

---

## Requirements

- Windows 10 or Windows 11 (32-bit or 64-bit)
- PowerShell 5.1 (included with Windows 10/11 -- no installation needed)
- Administrator rights (the launcher requests elevation automatically)
- Network access to `\\SyncServer\` for the optional file-copy steps

---

## How to Run

1. Open the folder containing both files (local drive or UNC network path such as `\\SyncServer\SyncScripts\`).
2. Double-click **`RunReset.cmd`**.
3. Click **Yes** on the UAC prompt.
4. Follow the on-screen prompts. Type `Y` to proceed with each step or `N` to skip it. Typing `N` at any required confirmation exits the script entirely.

> **Do not run `DisplayController-Reset.ps1` directly.** The `.cmd` launcher
> unblocks the script (removes the Zone.Identifier mark that causes *Unknown
> Publisher* errors on files opened from a network share) and ensures the
> correct execution policy is applied before PowerShell starts.

---

## What the Script Does

The procedure walks through 8 steps. Steps marked **(Optional)** will prompt
before running; you can skip them without cancelling the rest.

### Step 1 -- Kill Process* Tasks
Finds and force-stops any running process whose name starts with `Process`
(e.g. `ProcessDeviceManager.exe`). This must be done before files in the
Executable directory can be replaced.

### Step 2 -- Open and Navigate Explorer Windows
Opens two File Explorer windows and positions them side-by-side (left/right),
each filling half the screen:

| Side | Path |
|------|------|
| Left (TARGET) | `...\Processes\DeviceManager\Executable` on this machine |
| Right (SOURCE) | `\\SyncServer\Syncinstall\Updates\Executables\DeviceManager` |

If the server share is not reachable at the time this step runs, the right
window opens to the Network neighbourhood instead.

### Step 3 -- (Optional) Delete Local Executable Directory Contents
Deletes all files and sub-folders inside the local `Executable` directory.
Run this before copying fresh files from the server to ensure no old files
remain.

> Requires confirmation. Permanent -- files are not sent to Recycle Bin.

### Steps 4+5 -- (Optional) Copy DeviceManager Files from SyncServer
Copies the contents of `\\SyncServer\Syncinstall\Updates\Executables\DeviceManager`
into the local `Executable` directory.

**Prerequisites for this step:**
- Network Discovery must be **Enabled** on this machine.
- Password Protected Sharing must be **Disabled** on this machine.
- Verify these settings have not reverted before running.

The script pings SyncServer first and warns if it is unreachable, giving you
the option to continue anyway or skip.

### Step 6 -- Delete Configuration.xml
Deletes the Display Controller configuration file:

```
...\Brunswick\Sync\SyncInstall\Configuration\Configuration.xml
```

This is the key step that causes the machine to boot to the
*Unknown Configuration* screen.

> Requires confirmation. Permanent.

### Step 7 -- Rename the Computer
Renames this machine to a random 8-character alphanumeric name (e.g. `A3FX9KQM`).
The new name takes effect after the reboot in Step 8.

> Requires confirmation.

### Step 8 -- Restart the Computer
Initiates a forced restart with a 10-second countdown. After rebooting, the
Display Controller should present the **Unknown Configuration** screen.

> Requires confirmation.

---

## Install Path Detection

Brunswick Sync installs as a 32-bit application. The script automatically
detects which `Program Files` variant is in use on the target machine and
uses it for all file operations:

```
C:\Program Files (x86)\Brunswick\Sync\SyncInstall\Configuration\   <- checked first (most common)
C:\Program Files\Brunswick\Sync\SyncInstall\Configuration\          <- checked second
```

If neither path exists, the x86 path is assumed and shown in all messages so
the technician knows where to look.

---

## Server / Source Machine Safeguard

At startup the script performs two independent checks to detect whether it is
running on a **server or source machine** rather than a Display Controller.
If either check triggers, all destructive steps (3 through 8) are
**permanently blocked** for that session.

**Check 1 -- Computer name pattern match.**
The machine name is compared against these keywords (case-insensitive,
substring match):

| Pattern | Matches example |
|---------|----------------|
| `SYNCSERVER` | `SYNCSERVER`, `SYNCSERVER01` |
| `SERVER` | `SERVER`, `FILESERVER`, `PRTSERVER` |
| `SRV` | `SRV01`, `WEBSRV` |
| `SYNC` | `SYNC`, `SYNCBOX` |

**Check 2 -- Windows OS edition.**
`Win32_OperatingSystem.ProductType` is read via WMI:

| Value | Meaning | Action |
|-------|---------|--------|
| 1 | Workstation | Allowed |
| 2 | Domain Controller | Blocked |
| 3 | Member Server | Blocked |

When the safeguard triggers, a red warning banner is displayed listing the
computer name, OS edition, and which steps are blocked. Steps 1 and 2 (kill
processes, open Explorer) remain available as they are non-destructive.

**False positive?** If a Display Controller has a name that contains one of
the blocked keywords, rename the machine first so its name does not match
any of the patterns, then re-run the script.

To add more blocked name patterns, edit `$SERVER_NAME_PATTERNS` near the top
of `DisplayController-Reset.ps1`.

---

## Audit Log

Every run is appended to `DisplayController_Reset_Log.csv` in the same folder
as the scripts. The log is created automatically if it does not exist.

### Log columns

| Column | Description |
|--------|-------------|
| `Timestamp` | Date and time of the action (yyyy-MM-dd HH:mm:ss) |
| `Computer` | NetBIOS name of the machine that was reset |
| `IP` | First non-loopback IPv4 address at time of run |
| `MAC` | MAC address of the first active network adapter |
| `Step` | Internal step identifier (e.g. `7-DeleteConfig`) |
| `Result` | `OK`, `SKIP`, `WARN`, `FAIL`, or `BLOCKED` |
| `Detail` | Human-readable detail (paths used, counts, error messages) |

### Example rows

```csv
Timestamp,Computer,IP,MAC,Step,Result,Detail
2025-03-15 09:14:02,DC-LANE04,192.168.1.44,A4-C3-F0-12-88-01,1-KillProcesses,OK,Stopped ProcessDeviceManager PID=3412
2025-03-15 09:14:15,DC-LANE04,192.168.1.44,A4-C3-F0-12-88-01,7-DeleteConfig,OK,C:\Program Files (x86)\Brunswick\...\Configuration.xml
2025-03-15 09:14:17,DC-LANE04,192.168.1.44,A4-C3-F0-12-88-01,8-RenameComputer,OK,OldName=DC-LANE04  NewName=K7QX3RMN
2025-03-15 09:14:27,DC-LANE04,192.168.1.44,A4-C3-F0-12-88-01,9-Restart,OK,Reboot initiated
```

---

## Troubleshooting

**"Unknown Publisher" error or script won't run from the network share.**
Always launch via `RunReset.cmd`, not directly. The `.cmd` calls
`Unblock-File` on the `.ps1` before executing it, which removes the
Zone.Identifier flag Windows attaches to files downloaded or copied from
a network location.

**Left Explorer window opens to the wrong folder.**
The local Executable directory did not exist on this machine. The window
opens to the nearest existing parent folder instead. Check whether Brunswick
Sync is installed and that the installation path matches what the script
detected at startup (reported in the `[ INFO ]` lines at the beginning of
Step 2).

**Steps 4+5 fail with "Cannot reach SyncServer".**
Verify the following on the Display Controller before retrying:
- Control Panel > Network and Sharing Center > Advanced sharing settings
  - **Network Discovery**: Turn on
  - **Password Protected Sharing**: Turn off
- Confirm the settings were saved and have not reverted (a group policy or
  scheduled task can reset these silently).

**Script exits immediately after the UAC prompt.**
This can happen if the `.ps1` is still marked as blocked by Windows. Open
PowerShell as Administrator and run:
```powershell
Unblock-File -Path "\\SyncServer\SyncScripts\DisplayController-Reset.ps1"
```
Then retry via `RunReset.cmd`.

**The machine was identified as a server but it is a Display Controller.**
The computer name contains one of the blocked keywords (`SERVER`, `SYNC`,
`SRV`, or `SYNCSERVER`). Rename the machine to a name that does not contain
any of those strings, reboot, and re-run the script.

---

## Security Notes

- The script requests Administrator elevation through the standard Windows UAC
  mechanism. No credentials are stored or transmitted.
- `-ExecutionPolicy Bypass` is scoped to the single PowerShell process launched
  by `RunReset.cmd` and does not change the system-wide execution policy.
- The audit log is written in plain CSV with ASCII encoding. It contains
  computer names, IP addresses, and MAC addresses -- treat the log file with
  the same care as any other asset inventory record.

---

## Customisation

All site-specific values are defined as constants near the top of
`DisplayController-Reset.ps1` and can be edited with any text editor:

| Variable | Default | Description |
|----------|---------|-------------|
| `$TARGET_PROC_PREFIX` | `Process` | Name prefix of processes to kill in Step 1 |
| `$SERVER_EXE_DIR` | `\\SyncServer\Syncinstall\Updates\Executables\DeviceManager` | Source path on SyncServer for Steps 4+5 |
| `$SERVER_NAME_PATTERNS` | `SYNCSERVER, SERVER, SRV, SYNC` | Computer name keywords that trigger the server safeguard |
| `$RANDOM_NAME_LEN` | `8` | Length of the random name assigned in Step 7 |
| `$RANDOM_NAME_CHARS` | `A-Z 0-9` | Character set used for the random name |
