====================================================================
  Sync SocialFeed and TextEffects Backup/Restore Script
  README
====================================================================

PACKAGE CONTENTS
----------------
  Launch.cmd               - Double-click to run (CMD launcher)
  SyncBackupRestore.ps1    - Main PowerShell script
  SyncBackupRestore.json   - Configuration file (auto-created if missing)
  Backup\                  - Created automatically on first backup

HOW TO USE
----------
1. Place ALL files in the SAME folder (e.g., on a USB stick or Desktop).
2. Right-click "Launch.cmd" -> "Run as administrator"
   (Admin rights are required to write to Program Files)
3. Follow the on-screen menu.

FEATURES
--------
  * Backup    - Copies SocialFeed.txt and TextEffects.txt to a
                timestamped subfolder under .\Backup\
  * Restore   - Lists available backups, lets you pick a version,
                warns before overwriting, handles read-only files.
  * Auto-prune - Keeps the 3 newest backup versions (configurable).
  * Logging    - All activity logged to SyncBackupRestore.log

CONFIGURATION (SyncBackupRestore.json)
---------------------------------------
  SourceFolder       - Path to files being backed up
  FilesToBackup      - Array of file names to backup/restore
  MaxBackupVersions  - How many backup versions to keep (min. 3 recommended)
  BackupFolderName   - Subfolder name for backups (default: Backup)
  LogFileName        - Log file name

BACKUP FOLDER STRUCTURE
-----------------------
  .\Backup\
      27.05.2025-14.30\
          SocialFeed.txt
          TextEffects.txt
      27.05.2025-09.15\
          SocialFeed.txt
          TextEffects.txt
      26.05.2025-16.00\
          ...

COMPATIBILITY
-------------
  * Windows Server 2016 / 2019 / 2022
  * Windows 10 / 11
  * PowerShell 3.0 and above (including PowerShell 7 / pwsh)
  * Regional-setting safe (uses InvariantCulture internally)

TROUBLESHOOTING
---------------
  Q: "Execution Policy" error
  A: The CMD launcher sets -ExecutionPolicy Bypass automatically.
     If running .ps1 directly, use:
     powershell -ExecutionPolicy Bypass -File SyncBackupRestore.ps1

  Q: "Access denied" when restoring
  A: Run Launch.cmd as Administrator.

  Q: Source files not found
  A: Verify Brunswick Sync is installed and the path in
     SyncBackupRestore.json is correct for your system.

====================================================================
