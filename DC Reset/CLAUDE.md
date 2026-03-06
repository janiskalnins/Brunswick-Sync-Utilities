# CLAUDE.md -- Brunswick Display Controller Reset Utility

Guidance for Claude Code when reading, editing, or extending this project.

---

## Project Overview

A two-file PowerShell toolkit that resets Brunswick Display Controllers to the
"Unknown Configuration" screen. Runs on Windows 10/11, always launched via the
CMD wrapper. The script is used by field technicians, often from a UNC network
share, so robustness and clarity of output matter more than brevity.

---

## File Map

```
RunReset.cmd                        -- CMD launcher (always entry point)
DisplayController-Reset.ps1         -- All logic
DisplayController_Reset_Log.csv     -- Auto-created audit log (do not edit)
README.md                           -- End-user and technician documentation
CLAUDE.md                           -- This file
```

---

## Hard Rules -- Never Violate These

### ASCII only
The script must remain pure ASCII. No Unicode characters, smart quotes, em
dashes, or non-breaking spaces anywhere -- not in strings, comments, or output.
The files are deployed to machines where the active code page may not be UTF-8,
and are also written to a CSV log. Any non-ASCII byte will corrupt the log or
cause a parse error on older PowerShell hosts.

Test before committing: every string passed to `Write-Host`, `Out-File`, or
`Write-Log` must be expressible with characters in the 0x20-0x7E range.

### No folder creation in Explorer-related code
`Invoke-OpenAndNavigateExplorers` must NEVER call `New-Item`. If the target
directory does not exist, walk up to the nearest existing parent and open that
instead (current behaviour). Creating missing directories is the job of
`Invoke-CopyFromServer` only, and only when it is about to copy files into it.

### Never default Enter to Y
All three input functions (`Confirm-Continue`, `Ask-YesNo`, and the opening
prompt) must re-prompt with a yellow hint when the user presses Enter without
typing a character. Blank input must never be silently interpreted as "yes" on
any prompt -- especially not on the irreversible ones (delete, rename, reboot).

### Server safeguard must run before anything else
`Test-IsProtectedMachine` is called and its result stored in
`$script:IS_PROTECTED_MACHINE` before `Show-Banner` and before any user
interaction. This order must not change. The safeguard also applies in auto
mode -- `Invoke-AutoReset` checks `$script:IS_PROTECTED_MACHINE` as its very
first action and aborts if true.

### Do not add Unicode arrows, checkmarks, or box-drawing characters
Output lines use plain ASCII brackets: `[  OK  ]`, `[ INFO ]`, `[ WARN ]`,
`[ FAIL ]`, `[ SKIP ]`. Do not replace these with emoji, Unicode symbols, or
ANSI escape codes.

---

## Architecture

### Execution model
The script is a single flat file -- no modules, no dot-sourcing, no classes.
All state is held in `$script:` scoped variables. Functions are defined in
order (safeguard, UI helpers, logging, step functions, auto-reset, then the
linear main flow at the bottom).

### Main flow is linear
The bottom of the script is a straight top-to-bottom sequence of step blocks.
Each block calls `Assert-NotProtected` before any destructive action, then
either calls the step function directly (Step 1) or prompts first
(`Ask-YesNo` for optional steps, `Confirm-Continue` for irreversible ones).

### Auto mode
Triggered when the user types `all` at the opening prompt. Sets
`$script:AUTO_MODE = $true`, which causes the main flow to immediately branch
into `Invoke-AutoReset` and exit. Auto mode runs Steps 1, 6, 7, and 8 silently
with no prompts. It is a secret feature -- the visible prompt shows only
`[Y] Yes  [N] Cancel`.

### Path resolution
Brunswick Sync installs as a 32-bit application. At startup, the script probes
`$BRUNSWICK_BASE_X86` first, then `$BRUNSWICK_BASE_X64`, and assigns
`$BRUNSWICK_BASE` to whichever exists. Both `$LOCAL_EXE_DIR` and `$CONFIG_XML`
are derived from `$BRUNSWICK_BASE` using `Join-Path`. Never hardcode the full
paths to these two variables -- always derive them from `$BRUNSWICK_BASE`.

---

## Script-Scope Variables

These are set at the module level and read by multiple functions. Treat them
as read-only inside functions (never reassign from within a function).

| Variable | Type | Purpose |
|----------|------|---------|
| `$script:IS_PROTECTED_MACHINE` | bool | Set by `Test-IsProtectedMachine` at startup |
| `$script:AUTO_MODE` | bool | Set to `$true` when user enters "all" |
| `$script:LogInfoCached` | bool | Guards one-time IP/MAC collection in `Write-Log` |
| `$script:LogIP` | string | Cached IPv4 address for log rows |
| `$script:LogMAC` | string | Cached MAC address for log rows |
| `$script:LogHost` | string | Cached computer name for log rows |

---

## Functions Reference

### Safeguard
| Function | Description |
|----------|-------------|
| `Test-IsProtectedMachine` | Returns `$true` if name matches `$SERVER_NAME_PATTERNS` or OS ProductType > 1 |
| `Show-ProtectionBanner` | Prints the red blocked-steps banner |
| `Assert-NotProtected` | Call before each destructive step; logs BLOCKED and returns `$false` if protected |

### UI Helpers
| Function | Description |
|----------|-------------|
| `Show-Banner` | Clears screen, prints the cyan title header |
| `Write-Step` | Yellow `[Step N]` prefix line |
| `Write-OK` | Green `[  OK  ]` line |
| `Write-Info` | Cyan `[ INFO ]` line |
| `Write-Warn` | Magenta `[ WARN ]` line |
| `Write-Fail` | Red `[ FAIL ]` line |
| `Write-Skip` | DarkGray `[ SKIP ]` line |
| `Confirm-Continue` | Requires explicit Y/N; N exits the whole script |
| `Ask-YesNo` | Requires explicit Y/N; returns `$true` for Y |

### Logging
| Function | Description |
|----------|-------------|
| `Write-Log` | Appends one CSV row; creates file with header on first call |

### Step Functions
| Function | Step | Destructive |
|----------|------|-------------|
| `Invoke-KillProcessTasks` | 1 | No (process kill only) |
| `Invoke-OpenAndNavigateExplorers` | 2 | No |
| `Invoke-ClearLocalExeDir` | 3 | Yes -- deletes files |
| `Invoke-CopyFromServer` | 4+5 | Partial -- may create dir, overwrites files |
| `Invoke-DeleteConfig` | 6 | Yes -- deletes Configuration.xml |
| `Invoke-RenameComputer` | 7 | Yes -- renames machine |
| `Invoke-RestartNow` | 8 | Yes -- forces reboot |

### Auto Mode
| Function | Description |
|----------|-------------|
| `Invoke-AutoReset` | Runs steps 1, 6, 7, 8 without any prompts; checks safeguard first |

---

## Logging Contract

`Write-Log` must be called for every significant outcome of every step.
Use these exact Result values -- no others:

| Result | When to use |
|--------|-------------|
| `OK` | Step completed successfully |
| `SKIP` | Step was skipped (directory already empty, file not found, user skipped) |
| `WARN` | Step completed but with a non-fatal issue |
| `FAIL` | Step attempted but threw an exception or returned an error |
| `BLOCKED` | Step was prevented by the server safeguard |

The `Detail` field should be human-readable and include paths, counts, old/new
names, or error messages. Keep it under ~200 characters. No line breaks inside
the Detail string.

---

## Adding a New Step

1. Write a function named `Invoke-<StepName>` following the existing pattern:
   - Call `Write-Step N "description..."` at the top
   - Call `Write-Log` for every exit path (OK, SKIP, FAIL)
   - Wrap all real work in `try/catch`; call `Write-Fail` in the catch block
   - Never prompt the user from inside the function -- prompting is the main
     flow's responsibility
2. If the step is destructive, add `Assert-NotProtected "N-StepName"` in the
   main flow before the prompt. The function itself should not check this.
3. Use `Confirm-Continue` in the main flow for irreversible steps (delete,
   rename, reboot). Use `Ask-YesNo` for optional steps the user might skip.
4. If the step should be part of auto mode, add a call inside
   `Invoke-AutoReset` with a matching `[Auto N/M]` progress line.
5. Update the step numbers in `Show-ProtectionBanner` if the total step count
   changes.

---

## Input Function Rules

Three functions handle user input. Their behaviour must remain consistent:

```
Confirm-Continue   -- used for irreversible actions
                      blank Enter  ->  re-prompt with yellow hint (NEVER default Y)
                      N            ->  exit 0 (whole script, not just step)
                      Y            ->  proceed

Ask-YesNo          -- used for optional steps
                      blank Enter  ->  re-prompt with yellow hint (NEVER default Y)
                      Y            ->  returns $true
                      N            ->  returns $false (caller decides what to do)

Opening prompt     -- inline code in main flow
                      blank Enter  ->  re-prompt with yellow hint (NEVER default Y)
                      N            ->  exit 0
                      Y            ->  continue to normal flow
                      all/ALL      ->  set $script:AUTO_MODE = $true, continue
```

Never add a blank-Enter default to any of these. The only acceptable responses
are explicit keystrokes. This is intentional -- the script performs irreversible
operations and a misfire from an accidental Enter press must not be possible.

---

## Explorer Window Handling

`Invoke-OpenAndNavigateExplorers` uses `Shell.Application.Explore($path)`
(COM method) to open both windows. Do NOT switch this to
`Start-Process explorer.exe -ArgumentList "..."`. The `-ArgumentList` approach
is unreliable with paths containing spaces (such as
`C:\Program Files (x86)\...`) because PowerShell adds an extra layer of string
parsing before the argument reaches `explorer.exe`.

The function tracks windows by HWND snapshot (before/after each `Explore`
call) with a polling loop and 12-second timeout. This is intentional -- a
fixed `Start-Sleep` is not reliable on slow machines or network paths.

---

## UNC / Network Share Compatibility

The script must remain runnable from `\\SyncServer\SyncScripts\` without any
changes to the machine's PowerShell execution policy. This is guaranteed by
`RunReset.cmd` which:

1. Calls `Unblock-File` on the `.ps1` to strip the Zone.Identifier stream
2. Passes `-ExecutionPolicy Bypass` scoped to just that process

Do not remove either of those steps from `RunReset.cmd`.

The self-elevation block in the `.ps1` uses three separate statements to build
the `WindowsPrincipal` check instead of chaining type-casts across lines.
This is required -- the multi-line chained form fails to parse when loaded from
a UNC path. Do not refactor it back to the chained form.

```powershell
# CORRECT -- works on UNC paths
$currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin          = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# WRONG -- breaks on UNC paths, do not use
if (-not ([Security.Principal.WindowsPrincipal]
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole(...))
```

---

## What Not to Change Without Discussion

- The `$SERVER_NAME_PATTERNS` list -- adding patterns may block legitimate
  Display Controllers; removing them may allow the script to run on servers.
- The order of checks in `Test-IsProtectedMachine` -- name check runs before
  WMI to avoid a slow WMI call on obvious matches.
- The auto mode keyword `all` -- it is intentionally undocumented in the UI.
- The 10-second reboot countdown in `Invoke-RestartNow` and `Invoke-AutoReset`
  -- this is the minimum time for a technician to see the final log path before
  the screen disappears.
- Log file encoding (`ASCII`) -- changing to UTF-8 will add a BOM that breaks
  CSV imports in some versions of Excel.
