# Win11Migrator

Migrate your apps, files, and settings from one Windows 11 PC to another.

Win11Migrator scans a source machine for installed applications, user data, browser profiles, and system settings. It writes everything into a migration package with a JSON manifest, either straight to the other PC over the local network or to a USB drive, OneDrive, Google Drive or a share. Then it reinstalls and restores everything on the target machine through a step-by-step WPF wizard or the command line.

---

## Table of Contents

- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [Usage](#usage)
  - [Export (Source PC)](#export-source-pc)
  - [Import (Target PC)](#import-target-pc)
- [What Gets Migrated](#what-gets-migrated)
- [App Installation Methods](#app-installation-methods)
- [Transfer Methods](#transfer-methods)
- [Configuration](#configuration)
- [Migration Package Format](#migration-package-format)
- [Building from Source](#building-from-source)
- [Running Tests](#running-tests)
- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Known Limitations](#known-limitations)
- [License](#license)

---

## Requirements

| Requirement | Details |
|---|---|
| **Operating System** | Windows 11 (both source and target) |
| **PowerShell** | 5.1 (ships with Windows 11; do **not** use PowerShell 7 -- WPF requires Windows PowerShell) |
| **Privileges** | Administrator recommended. Required on the target machine for app installation. |
| **Disk Space** | Enough free space on the transfer medium to hold the migration package |

Win11Migrator checks the releases of the repository named by `UpdateRepository` in `Config\AppSettings.json` (`Aurumdev952/Win11Migrator`) at startup, no more than once every 24 hours. Before installing an update it verifies the download: against `UpdateSignerSubject` when that is set (signed builds), otherwise against the SHA-256 in the release's `SHA256SUMS.txt`. Run `Win11Migrator.ps1 -CheckForUpdates` for an immediate check.

Optional tools that enhance functionality (detected automatically at runtime):

| Tool | Purpose |
|---|---|
| [WinGet](https://github.com/microsoft/winget-cli) | Primary app install method (pre-installed on Windows 11 22H2+) |
| [Chocolatey](https://chocolatey.org/) | Secondary app install method (auto-bootstrapped on target if needed) |

---

## Getting Started

Download from the [Releases page](https://github.com/Aurumdev952/Win11Migrator/releases). Each release has three forms of the same app:

| File | Use it when |
|---|---|
| `Win11Migrator-<version>-x64.msi` | Installing on a PC, or deploying with Intune, SCCM or Group Policy. Installs to `Program Files\Aurumdev952\Win11Migrator` with Start menu and desktop shortcuts, upgrades in place, and uninstalls from Settings > Apps. Silent: `msiexec /i Win11Migrator-<version>-x64.msi /qn`. |
| `Win11Migrator-<version>-portable.exe` | Running once without installing, e.g. from a USB stick. It unpacks to `%LOCALAPPDATA%\Win11Migrator\portable\<version>` on first run. |
| `Win11Migrator-<version>-portable.zip` | Environments that block downloaded executables. Extract and double-click `Win11Migrator.bat`. |
| `SHA256SUMS.txt` | Checking a download: `Get-FileHash <file> -Algorithm SHA256` must match. |

### Option 1: Double-click (recommended for non-technical users)

1. Install the MSI (or extract the zip, or run the portable exe).
2. Start **Win11Migrator** from the Start menu (or double-click `Win11Migrator.bat`).
3. Accept the UAC elevation prompt.
4. The wizard GUI opens automatically.

The `.bat` launcher requests elevation and runs the script with `-ExecutionPolicy Bypass` for that one process. It does not change system policy or any security setting.

### Windows SmartScreen and Microsoft Defender

Release builds are currently **unsigned**. On a PC that downloads one, SmartScreen may say "Windows protected your PC". Choose **More info > Run anyway**, after checking the file against `SHA256SUMS.txt` from the same release. The zip and the MSI rarely trigger this; the portable exe is the most likely to.

Versions before 1.1.0 changed security settings from `Win11Migrator.bat`: they turned off Defender real-time protection, excluded all PowerShell scripts and `powershell.exe` from scanning, set the machine execution policy to Bypass, and disabled AMSI for the session. That behaviour is gone, and it was the main reason antivirus flagged the tool. On PCs that ran an older version, run this as administrator to undo it:

```powershell
.\Tools\Remove-LegacyDefenderChanges.ps1 -WhatIf               # show what would change
.\Tools\Remove-LegacyDefenderChanges.ps1 -ResetExecutionPolicy # undo it
```

If Defender still flags a release, submit the file as a false positive at the [Microsoft Security Intelligence portal](https://www.microsoft.com/en-us/wdsi/filesubmission).

To have releases signed, add two repository secrets: `WIN11MIGRATOR_SIGN_PFX` (the base64 of a code-signing `.pfx`) and `WIN11MIGRATOR_SIGN_PASSWORD`. The build then signs every script, the portable exe and the MSI with a timestamp. Also set `UpdateSignerSubject` in `AppSettings.json` to the certificate's subject (for example `CN=Your Org`), so the updater requires that signature. Certificates whose key lives in a cloud HSM (SSL.com eSigner, DigiCert KeyLocker, Azure Key Vault) need their vendor's signing step in place of the pfx. Signing does not remove SmartScreen warnings straight away: Microsoft builds reputation for a new publisher over a few weeks of clean downloads.

### Option 2: PowerShell

```powershell
# Open an elevated (Run as Administrator) PowerShell prompt
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Win11Migrator.ps1
```

### Parameters

```
Win11Migrator.ps1 [-CLI <action>] [options]
```

| Parameter | Description |
|---|---|
| `-CLI scan` | Scan this PC and list apps, data, browsers and settings |
| `-CLI export` | Export a package to `-PackagePath` (default `MigrationPackage\`), or straight to another PC with `-SendTo` |
| `-CLI receive` | Wait for another PC on the network to send its package, then restore it (needs administrator) |
| `-CLI import -PackagePath <path>` | Restore a package |
| `-CLI validate`, `status`, `diff`, `healthcheck`, `rollback` | Package checks and post-migration tools |
| `-SendTo <PC> -PairingCode <code>` | With `export`: write directly into a PC waiting in `receive` mode |
| `-NetworkTarget <PC> -TargetCredential <cred> -TargetUser <user>` | With `export`: push to a domain PC's admin share; the restore runs when that user signs in |
| `-Resume` | With `export`: continue an unfinished package from this PC instead of starting over |
| `-ExcludeDir <names>`, `-ExcludeFile <patterns>` | Skip more folder names or file patterns, on top of the configured defaults |
| `-Profile <name>` | Apply a migration profile from `Config\MigrationProfiles\` |
| `-MoveFromPackage` | With `import`: move files into place instead of copying (same volume only; consumes the package) |
| `-Backup [-Incremental] [-BackupPath <path>]` | Headless backup; `-Incremental` refreshes one rolling folder |
| `-ScheduleBackup` | Register a weekly incremental backup task |
| `-Silent` | No console output; writes `migration-result.json` |

---

## Usage

### Same network: Receive (fastest)

When both PCs are on the same network, nothing needs to be carried between them.

1. On the **new** PC, start Win11Migrator as administrator and choose **Receive**. It shows a pairing code such as `KQ7M-3XPA`.
2. On the **old** PC, choose **Export**. On the transfer step, pick **Another PC on this network**, select the new PC (or type its name or IP address), enter the code and click **Connect**.
3. The old PC writes the package straight into the new PC, with SMB compression. As soon as the app list arrives, the new PC starts installing apps while files are still coming in.
4. When the transfer finishes, the new PC moves the received folders into the profile (a rename on the same disk, not a second copy) and restores browsers and settings.

The new PC opens a hidden share writable only by a temporary local account whose password is derived from the pairing code, plus temporary SMB and discovery (UDP 50717) firewall rules. All of these are removed when the transfer completes, when the window closes, or on the next start after a crash. It works on workgroup and domain PCs and needs no WinRM.

From the command line: `Win11Migrator.ps1 -CLI receive` on the new PC, then `Win11Migrator.ps1 -CLI export -SendTo NEWPC -PairingCode KQ7M-3XPA` on the old one.

### Export (Source PC)

Run Win11Migrator on the PC you are migrating **from**.

1. **Welcome** -- Select **Export**.
2. **Scan** -- The tool automatically scans for:
   - Installed applications (registry, WinGet, Microsoft Store, Program Files)
   - User data folders (Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites)
   - Browser profiles (Chrome, Edge, Firefox, Brave)
   - System settings (WiFi, printers, mapped drives, environment variables, Windows preferences)
3. **App Selection** -- Review the discovered app list. Each app shows its detected install method (WinGet, Chocolatey, Ninite, Store, Vendor Download, or Manual). Use the search box to filter. Select or deselect individual apps.
4. **Data Selection** -- Toggle which user data folders, browser profiles, and system settings categories to include. Folder sizes are shown next to each item.
5. **Storage Selection** -- Choose a transfer method:
   - **Another PC on this network** -- Send directly to a PC waiting in Receive mode (see above)
   - **Push to a domain PC** -- Write to another PC's admin share with its admin credentials; the restore starts when the user signs in
   - **USB Drive** -- Select from detected removable drives
   - **OneDrive** -- Copies to your OneDrive sync folder
   - **Google Drive** -- Copies to your Google Drive sync folder
   - **Custom Folder** -- Browse to any local or network path
6. **Export** -- The package is written directly into the destination, so data crosses each medium once. The export stops before copying anything if the destination is too small. If an earlier export to the same place was interrupted, you are offered **Resume**, which skips files already copied. The progress page shows MB/s and the time remaining.
7. **Complete** -- Review the summary. For cloud transfers, wait for the sync to finish before proceeding to the target machine.

### Import (Target PC)

Run Win11Migrator on the PC you are migrating **to**.

1. **Welcome** -- Select **Import**.
2. **Select Package** -- Browse to the migration package folder, or select from auto-detected packages found on USB drives and cloud sync folders.
3. **Import** -- The tool reads `manifest.json` and performs the following in order:
   1. **Install applications and restore user data at the same time** -- Apps install one after another in a background runspace (WinGet, Chocolatey, Ninite, Store, or direct download) while files are copied back to the profile folders. Failed installs are logged but do not stop the pipeline.
   2. **Restore user data** -- Profile folders go to the matching known folders (OneDrive redirection is honoured); custom folders go under the user profile by name.
   3. **Restore browser profiles** -- Restores bookmarks, preferences, and history. Generates an HTML page with extension reinstall links for each browser.
   4. **Restore system settings** -- Re-imports WiFi profiles, printer configurations, mapped network drives, environment variables, and Windows settings.
   5. **Restore AppData** -- Merges exported AppData folders into the target profile.
   6. **Generate reports** -- Creates an HTML completion report and a manual install guide for any apps that could not be automated.
4. **Complete** -- Review statistics and open the generated reports. A restart is recommended to apply all changes.

---

## What Gets Migrated

### Applications

| Source | Method |
|---|---|
| Registry uninstall keys (`HKLM`, `HKCU`, `WOW6432Node`) | Scans `DisplayName`, `DisplayVersion`, `Publisher`, `InstallLocation`, `UninstallString` |
| WinGet package list | Parses `winget list` output; pre-resolves package IDs |
| Microsoft Store apps | Filters `Get-AppxPackage`; excludes frameworks, system packages, and runtime components |
| Program Files folders | Fallback scanner; reads `FileVersionInfo` from discovered `.exe` files |

App names are normalized (stripped of version numbers, architecture tags, edition markers) and deduplicated across all sources using weighted metadata scoring. A fuzzy matching engine (Levenshtein distance + Jaccard similarity) resolves each app against package managers.

### User Data

The following profile folders are scanned and exported via Robocopy:

- Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites
- Selected AppData folders (Sticky Notes, Windows Themes, Credentials -- configurable)

OneDrive Known Folder Move redirection is detected automatically through the registry (`User Shell Folders`).

### Exclusions

Folders that can be rebuilt are skipped by name, anywhere inside the selected folders: `node_modules`, `.venv`, `venv`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.gradle`, `.next`, `.nuxt`, `.parcel-cache`, `.turbo`, `bower_components`, `.terraform`, `$RECYCLE.BIN` and `System Volume Information`. Files matching `*.tmp`, `~$*`, `Thumbs.db`, `desktop.ini`, `*.log` and `*.pyc` are skipped too, as are files larger than `MaxFileSizeMB`.

- Change the defaults in `Config\AppSettings.json` (`ExcludeDirectories`, `ExcludeFilePatterns`).
- A migration profile can add to them with an `Exclusions` block; the Developer profile adds `target`, `.angular`, `.svelte-kit`, `.dart_tool`, `.expo` and `DerivedData`.
- In the wizard, **Data Selection > Excluded folders and file types** shows the full lists; edit them and click **Apply and re-measure**. Folder sizes on that page already account for exclusions.
- On the command line, add more with `-ExcludeDir` and `-ExcludeFile`.

The lists used are recorded in `manifest.json` under `Metadata.Exclusions`.

### Browser Profiles

| Browser | Bookmarks | Preferences | History | Extensions | Passwords |
|---|---|---|---|---|---|
| Google Chrome | Yes | Yes | Yes | List + Web Store links | **No** (security) |
| Microsoft Edge | Yes | Yes | Yes | List + Add-ons links | **No** |
| Mozilla Firefox | Yes (`places.sqlite`) | Yes (`prefs.js`) | Yes | List + AMO links | **No** |
| Brave | Yes | Yes | Yes | List + Web Store links | **No** |

Passwords are intentionally never exported. On import, an HTML page is generated per browser with direct links to reinstall each extension from the appropriate store.

### System Settings

| Category | Export Method | Import Method |
|---|---|---|
| WiFi Profiles | `netsh wlan export profile` (XML with cleartext keys) | `netsh wlan add profile` |
| Printers | `Get-Printer` + `Get-PrinterPort` metadata | `Add-Printer` / `Add-PrinterPort` (network reconnect or local rebuild) |
| Mapped Drives | Registry (`HKCU:\Network`) + `net use` | `net use` with persistence flag |
| Environment Variables | `[System.Environment]::GetEnvironmentVariables('User')` | `SetEnvironmentVariable` with PATH merging (additive, not overwrite) |
| Windows Settings | File associations (`FileExts` registry), taskbar pins (`.lnk` shortcuts + `Taskband` binary), Start Menu layout | Best-effort restore (Windows protects some settings with hashes) |

---

## App Installation Methods

The install method resolver uses a cascade with confidence scoring. For each app, it tries each source in order and selects the first match above the confidence threshold:

| Priority | Method | Source | Notes |
|---|---|---|---|
| 1 | **WinGet** | `winget search` | Primary method. Silent install via `winget install --silent`. |
| 2 | **Chocolatey** | `choco search` / community API | Auto-bootstraps Chocolatey on target if not present. |
| 3 | **Ninite** | Local catalog (`NiniteAppList.json`, 55+ apps) | Free tier limitations logged. |
| 4 | **Microsoft Store** | Local catalog (`StoreAppCatalog.json`, 30+ apps) | Falls back to opening the Store page if `winget --source msstore` fails. |
| 5 | **Vendor Download** | URL database (`VendorDownloadUrls.json`, 30+ apps) | Downloads MSI/EXE, attempts common silent switches (`/S`, `/silent`, `/VERYSILENT`, `/quiet`). |
| 6 | **Manual** | N/A | Listed in the manual install HTML report with download links where available. |

Each install method has a configurable timeout (default 600 seconds) and uses the retry wrapper (default 3 attempts with 5-second delays). Apps are installed sequentially to avoid MSI mutex conflicts. Individual failures never abort the pipeline.

---

## Transfer Methods

| Method | How It Works | Requirements |
|---|---|---|
| **Another PC on this network** | The target opens a temporary share; the source writes the package into it directly (robocopy `/COMPRESS`, 16 threads). Apps start installing on the target as soon as the manifest arrives. | Both PCs on the same network; administrator on the target |
| **Push to a domain PC** | The source writes to `\\TARGET\C$\Win11Migrator` with admin credentials and registers a one-time logon task that restores as the target user. | Admin credentials for the target; WinRM or DCOM for the task (otherwise the user starts the import by hand) |
| **USB Drive** | Detected via WMI (`Win32_DiskDrive` chain). The package is written straight to the drive with 4 robocopy threads, which suits flash media. | USB drive with sufficient free space |
| **OneDrive** | Detected via `$env:OneDrive`, registry (`HKCU:\SOFTWARE\Microsoft\OneDrive`), and environment variables. Written to a `Win11Migrator/` subfolder in the sync root. | OneDrive desktop app signed in and syncing |
| **Google Drive** | Detected via `$env:LOCALAPPDATA\Google\DriveFS`, registry, and common user profile paths. Written to a `Win11Migrator/` subfolder. | Google Drive for Desktop installed and syncing |
| **Network Share / Custom Folder** | Any local or UNC path; the package goes in a `Win11Migrator/` subfolder. | Target path must be writable |

Every destination except Receive mode gets a copy of Win11Migrator next to the package, so the new PC can run it from there. Cloud methods rely on the desktop sync client rather than APIs, avoiding OAuth complexity.

---

## Configuration

All settings are in **`Config/AppSettings.json`**:

```json
{
  "Version": "1.0.0",
  "LogLevel": "Info",
  "LogDirectory": "Logs",
  "MigrationPackageDirectory": "MigrationPackage",
  "MaxRetryCount": 3,
  "RetryDelaySeconds": 5,
  "DiskSpaceBufferMB": 500,
  "RobocopyThreads": 8,
  "RobocopyThreadsByTarget": { "Local": 16, "Network": 16, "USB": 4, "Cloud": 8 },
  "RobocopyRetries": 1,
  "RobocopyWaitSeconds": 1,
  "RobocopyUnbufferedIO": false,
  "UserDataFolders": ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music", "Favorites"],
  "AppDataInclude": ["Microsoft\\Sticky Notes", "Microsoft\\Windows\\Themes", "Microsoft\\Credentials"],
  "ExcludeFilePatterns": ["*.tmp", "~$*", "Thumbs.db", "desktop.ini", "*.log", "*.pyc"],
  "ExcludeDirectories": ["node_modules", ".venv", "__pycache__", "..."],
  "MaxFileSizeMB": 4096,
  "EnableWinget": true,
  "EnableChocolatey": true,
  "EnableNinite": true,
  "EnableStoreApps": true,
  "EnableVendorDownload": true,
  "SilentInstallTimeout": 600,
  "BrowserProfiles": { "Chrome": true, "Edge": true, "Firefox": true, "Brave": true },
  "SystemSettings": { "WiFiProfiles": true, "Printers": true, "MappedDrives": true, "EnvironmentVariables": true, "WindowsSettings": true }
}
```

| Setting | Default | Description |
|---|---|---|
| `LogLevel` | `Info` | Minimum log level: `Debug`, `Info`, `Warning`, `Error` |
| `LogDirectory` | `Logs` | Relative path for log files (auto-created) |
| `MigrationPackageDirectory` | `MigrationPackage` | Local staging directory for export packages |
| `MaxRetryCount` | `3` | Retry attempts for transient failures (installs, file copies) |
| `RetryDelaySeconds` | `5` | Seconds between retries |
| `DiskSpaceBufferMB` | `500` | Extra headroom required beyond estimated package size |
| `RobocopyThreadsByTarget` | 16 / 16 / 4 / 8 | Robocopy `/MT` threads for local, network, USB and cloud-folder destinations |
| `RobocopyRetries` / `RobocopyWaitSeconds` | `1` / `1` | Robocopy `/R` and `/W`; locked files rarely unlock within seconds, so failing fast keeps large copies moving |
| `RobocopyUnbufferedIO` | `false` | Add `/J` (unbuffered I/O), which helps on very large files and hurts on many small ones |
| `UserDataFolders` | 7 folders | Which profile folders to scan and export |
| `AppDataInclude` | 3 folders | Which `%APPDATA%` / `%LOCALAPPDATA%` subfolders to include |
| `ExcludeFilePatterns` | 6 patterns | File patterns excluded from every copy (`/XF`) |
| `ExcludeDirectories` | 17 names | Folder names excluded anywhere in the selected folders (`/XD`) |
| `MaxFileSizeMB` | `4096` | Skip individual files larger than this |
| `Enable*` | all `true` | Toggle individual install methods on/off |
| `SilentInstallTimeout` | `600` | Seconds before killing a hung installer process |
| `BrowserProfiles.*` | all `true` | Toggle individual browser scanning |
| `SystemSettings.*` | all `true` | Toggle individual system settings categories |

### Additional Config Files

| File | Purpose |
|---|---|
| `Config/ExcludedApps.json` | Wildcard patterns for apps to skip during discovery (runtimes, drivers, OEM bloatware -- 50+ patterns) |
| `Config/NiniteAppList.json` | Map of normalized app names to Ninite slugs (55+ apps) |
| `Config/VendorDownloadUrls.json` | Map of app names to `{ Url, SilentArgs, InstallerType }` objects (30+ apps) |
| `Config/StoreAppCatalog.json` | Map of app names to `{ StoreId, PackageFamilyName }` objects (30+ apps) |

---

## Migration Package Format

An exported migration package is a folder with the following structure:

```
Win11Migration_COMPUTERNAME_20260226_143052/
    manifest.json              # Machine info, app list, data inventory, settings (written first, rewritten at the end)
    transfer.json              # InProgress / Complete / Failed, bytes copied; read by a receiving PC and by -Resume
    Apps/
        winget-packages.json   # `winget export` output, usable with `winget import` by hand
    UserData/
        Desktop/               # Robocopy mirror of user's Desktop
        Documents/
        Downloads/
        ...
    AppData/
        Roaming/               # Selected AppData\Roaming subfolders
        Local/                 # Selected AppData\Local subfolders (1.0.x packages nested these under AppData\AppData; both restore)
    BrowserProfiles/
        Chrome_Default/        # Bookmarks, Preferences, History, extensions_list.json
        Edge_Default/
        Firefox_default-release/
        Brave_Default/
    SystemSettings/
        WiFi/                  # Exported XML profiles
        Printers/              # Printer metadata (in manifest)
        MappedDrives/          # Drive mappings (in manifest)
        EnvVars/               # Environment variables (in manifest)
        WindowsSettings/       # File associations, taskbar pins, Start layout
    Reports/                   # Generated on import
        CompletionReport.html
        ManualInstallReport.html
```

### manifest.json

The manifest is the authoritative record of the migration. Structure:

```json
{
  "Version": "1.0.0",
  "ExportDate": "2026-02-26T14:30:52.0000000-05:00",
  "SourceComputerName": "DESKTOP-ABC123",
  "SourceOSVersion": "Microsoft Windows NT 10.0.22631.0",
  "SourceUserName": "john",
  "Apps": [
    {
      "Name": "Google Chrome",
      "NormalizedName": "google chrome",
      "Version": "122.0.6261.95",
      "Publisher": "Google LLC",
      "Source": "Registry",
      "InstallMethod": "Winget",
      "PackageId": "Google.Chrome",
      "MatchConfidence": 0.95,
      "Selected": true,
      "InstallStatus": "Pending"
    }
  ],
  "UserData": [...],
  "BrowserProfiles": [...],
  "SystemSettings": [...],
  "Metadata": {}
}
```

---

## Building from Source

On Windows with the WiX Toolset CLI installed (`dotnet tool install --global wix --version 5.0.2`):

```powershell
.\build\Build-Release.ps1            # MSI, portable exe, portable zip and SHA256SUMS.txt in .\dist
.\build\Build-Release.ps1 -SkipMsi   # portable artifacts only, no WiX needed
```

The version comes from `Version` in `Config\AppSettings.json` and must be `major.minor.patch`.

### Continuous integration and releases

`.github/workflows/ci.yml` runs on every push and pull request. It runs the linter and the Pester suite on Windows PowerShell 5.1, builds all artifacts, and smoke-tests them: it installs and uninstalls the MSI, runs the zip, and launches the portable exe. The artifacts are attached to the workflow run.

To publish a release:

1. Set `Version` in `Config\AppSettings.json` (for example `1.2.0`) and merge to `main`.
2. Tag that commit and push the tag: `git tag v1.2.0 && git push origin v1.2.0`.
3. The workflow checks that the tag matches the version, builds, and creates the GitHub release with all files attached.

---

## Running Tests

The tests use [Pester](https://pester.dev/) 5. Windows PowerShell 5.1 ships with Pester 3, so install 5 first:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser

# Everything (on Windows)
Invoke-Pester -Path .\Tests\ -Output Detailed

# The cross-platform part, e.g. on Linux or macOS with pwsh
$c = New-PesterConfiguration; $c.Run.Path = './Tests'; $c.Filter.ExcludeTag = 'Windows'; Invoke-Pester -Configuration $c

# Lint as CI does
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

GitHub Actions (`.github/workflows/test.yml`) runs the linter and the full suite under Windows PowerShell 5.1 on every push and pull request.

### Test Suites

| File | Coverage |
|---|---|
| `Tests/Robocopy.Tests.ps1` | Robocopy arguments per destination, exclusions, quoting, live byte parsing, English and French job summaries, rate display |
| `Tests/Exclusions.Tests.ps1` | Merging defaults, profiles and user additions; path matching; config validation rules |
| `Tests/Export.Tests.ps1` | Destination resolution and space checks, manifest-first ordering, exclusions reaching robocopy, cloud folders, duplicate names, AppData layout, resume |
| `Tests/Import.Tests.ps1` | Restore paths, move vs copy, conflicts, AppData from new and 1.0.x packages, read-only packages, installs overlapping file restore |
| `Tests/Receive.Tests.ps1` | Pairing codes, derived password, incoming package states, UDP discovery over loopback, and a send-to-restore run with the share replaced by a folder |
| `Tests/AdminShare.Tests.ps1` | Logon restore command, connection test when ping is blocked |
| `Tests/Winget.Tests.ps1` | Which `winget list` rows can be reinstalled, truncated IDs |
| `Tests/Core.Tests.ps1`, `AppDiscovery.Tests.ps1`, `UserData.Tests.ps1`, `Integration.Tests.ps1` | Config, classes, logging, retry, manifest round-trip, name normalization, catalogs, profile detection (the last two need Windows) |

---

## Project Structure

```
Win11Migrator/
    Win11Migrator.ps1              # Entry point: loads all modules, initializes environment, launches GUI
    Win11Migrator.bat              # Double-click launcher: handles UAC elevation and execution policy
    build/
        Build-Release.ps1          # Builds the MSI, portable exe, portable zip and checksums
        PortableLauncher.cs        # Source of the portable exe
    Tools/
        Remove-LegacyDefenderChanges.ps1  # Undo the security changes made by launchers before 1.1.0
    .github/workflows/
        ci.yml                     # Test, build, smoke-test, and release on v* tags
        test.yml                   # Lint and Pester (reused by ci.yml)
    README.md
    LICENSE

    Config/
        AppSettings.json           # All runtime settings and feature flags
        ExcludedApps.json          # Wildcard patterns for apps to skip (runtimes, drivers, bloatware)
        NiniteAppList.json         # Normalized app name -> Ninite slug mapping
        VendorDownloadUrls.json    # App name -> { Url, SilentArgs, InstallerType } mapping
        StoreAppCatalog.json       # App name -> { StoreId, PackageFamilyName } mapping

    Core/
        Initialize-Environment.ps1 # PowerShell class definitions, config loading, prerequisite checks
        Write-MigrationLog.ps1     # Logging to file + concurrent queue for GUI + verbose stream
        Test-AdminPrivilege.ps1    # Admin check and elevation request
        Invoke-WithRetry.ps1       # Generic retry wrapper with configurable attempts and delay
        Get-DiskSpaceEstimate.ps1  # Estimate package size, verify target has sufficient space
        ConvertTo-MigrationManifest.ps1  # Serialize scan results to manifest.json
        Read-MigrationManifest.ps1       # Deserialize and validate manifest with typed reconstruction
        Invoke-Robocopy.ps1        # The one robocopy wrapper: tuned flags, streamed output, byte progress, locale-proof summary
        Get-MigrationExclusions.ps1  # Merge folder and file exclusions from config, profile and user
        Invoke-MigrationExport.ps1 # The export engine shared by GUI, CLI, backup and network sends
        Invoke-MigrationImport.ps1 # The import engine: installs apps while restoring files

    Modules/
        AppDiscovery/
            Get-InstalledApps.ps1      # Orchestrator: calls all scanners, deduplicates by weighted metadata score
            Get-RegistryApps.ps1       # HKLM + HKCU + WOW6432Node uninstall key scanner
            Get-WingetApps.ps1         # Parses `winget list`; keeps only IDs `winget export` can reinstall
            Get-StoreApps.ps1          # Filters Get-AppxPackage (excludes frameworks, system packages)
            Get-ProgramFilesApps.ps1   # Fallback: scans Program Files folders for .exe FileVersionInfo
            Get-NormalizedAppName.ps1  # Name normalization + Levenshtein distance + Jaccard similarity
            Resolve-InstallMethod.ps1  # Cascade resolver: WinGet > Choco > Ninite > Store > Vendor > Manual
            Search-WingetPackage.ps1   # Fuzzy match against `winget search` output, cached per product
            Search-ChocolateyPackage.ps1  # CLI search + OData v2 API fallback
            Search-NinitePackage.ps1   # Exact + fuzzy match against NiniteAppList.json
            Search-StorePackage.ps1    # Exact + fuzzy match against StoreAppCatalog.json
            Search-VendorDownload.ps1  # Exact + fuzzy match against VendorDownloadUrls.json

        AppInstaller/
            Invoke-AppInstallPipeline.ps1 # Sequential orchestrator: groups by method, retries, progress callbacks
            Install-AppViaWinget.ps1      # winget install --id <PackageId> --silent
            Install-AppViaChocolatey.ps1  # choco install <PackageId> -y --no-progress
            Install-Chocolatey.ps1        # Bootstrap Chocolatey on target if not present
            Install-AppViaNinite.ps1      # Download and run Ninite per-app installer
            Install-AppViaStore.ps1       # winget --source msstore, falls back to opening Store page
            Install-AppViaDownload.ps1    # Download MSI/EXE, detect type, try common silent switches

        UserData/
            Get-UserProfilePaths.ps1   # Resolve actual paths via registry; detect OneDrive KFM redirection
            Export-UserProfile.ps1     # Copy selected folders through Invoke-Robocopy with exclusions
            Import-UserProfile.ps1     # Restore to the known folders (or under the profile for custom folders)
            Restore-PackageFolder.ps1  # Move into place on the same volume, else copy
            Export-AppDataSettings.ps1 # Copy selected Roaming/Local AppData subfolders
            Import-AppDataSettings.ps1 # Restore AppData with path remapping

        BrowserProfiles/
            Get-BrowserProfilePaths.ps1    # Detect all browsers, enumerate profiles, check for data files
            Export-ChromeProfile.ps1        # Bookmarks, Preferences, History, extension list (no passwords)
            Export-EdgeProfile.ps1          # Same as Chrome (Chromium-based)
            Export-FirefoxProfile.ps1       # places.sqlite, prefs.js, extensions.json (no logins.json)
            Export-BraveProfile.ps1         # Same as Chrome (Chromium-based)
            Import-ChromeProfile.ps1        # Restore files + generate extension reinstall HTML
            Import-EdgeProfile.ps1          # Restore files + generate extension reinstall HTML
            Import-FirefoxProfile.ps1       # Restore profile files + extension HTML
            Import-BraveProfile.ps1         # Restore files + generate extension reinstall HTML

        SystemSettings/
            Export-WiFiProfiles.ps1         # netsh wlan export (XML with cleartext keys)
            Import-WiFiProfiles.ps1         # netsh wlan add profile
            Export-PrinterConfigs.ps1       # Get-Printer + Get-PrinterPort metadata capture
            Import-PrinterConfigs.ps1       # Add-Printer / Add-PrinterPort reconstruction
            Export-MappedDrives.ps1         # Registry (HKCU:\Network) + net use
            Import-MappedDrives.ps1         # net use recreation with credential handling
            Export-WindowsSettings.ps1      # File associations, taskbar pins (.lnk + Taskband), Start layout
            Import-WindowsSettings.ps1      # Best-effort restore of associations, pins, and layout
            Export-EnvironmentVariables.ps1 # User-scope env vars with PATH split for merging
            Import-EnvironmentVariables.ps1 # SetEnvironmentVariable with additive PATH merge

        StorageTargets/
            Get-USBDrives.ps1              # WMI disk chain detection for removable USB drives
            Find-CloudSyncFolders.ps1      # Detect OneDrive and Google Drive sync roots
            Resolve-ExportDestination.ps1  # Map the chosen target to a package folder; check free space
            Copy-MigratorToTarget.ps1      # Bundle the tool next to the package

        NetworkTransfer/
            ReceiveProtocol.ps1            # Pairing codes, derived password, discovery messages, incoming state
            Start-ReceiveSession.ps1       # Target: temporary account, share, firewall rules, discovery responder
            Connect-ReceiveSession.ps1     # Source: find receivers, connect with the code
            Register-RemoteRestoreTask.ps1 # Domain push: map C$, schedule the restore at user sign-in
            Test-RemoteAccess.ps1          # Ping, WinRM, admin share and PSSession checks
            Find-NetworkComputers.ps1      # AD, ARP, net view and ping-sweep discovery

    GUI/
        MainWindow.xaml                # WPF window shell with header, content frame, footer nav
        MainWindow.ps1                 # Window logic, wizard navigation, background runspace management
        Styles/
            Colors.xaml                # Color palette and brush resources
            Typography.xaml            # Font families and text styles
            Controls.xaml              # Button, TextBox, CheckBox, ProgressBar, Card templates
            Icons.xaml                 # Path-based vector icons (Material Design geometry)
        Pages/
            WelcomePage.xaml + .ps1        # Export, Import or Receive
            ReceivePage.xaml + .ps1        # Pairing code, live receive progress, early app installs
            ScanProgressPage.xaml + .ps1   # Background scanning with per-phase progress indicators
            AppSelectionPage.xaml + .ps1   # Filterable checkbox list with install method badges
            DataSelectionPage.xaml + .ps1  # Toggle data categories; background sizing; exclusion editor
            StorageSelectionPage.xaml + .ps1  # Another PC / domain push / USB / OneDrive / Google Drive / share / folder
            NetworkTargetPage.xaml + .ps1     # Credentials and connection test for the domain push
            ExportProgressPage.xaml + .ps1    # Multi-phase export with log viewer
            ImportSourcePage.xaml + .ps1      # Browse for package + auto-detect on USB/cloud
            ImportProgressPage.xaml + .ps1    # Install + restore progress with success/fail counters
            CompletionPage.xaml + .ps1        # Summary statistics, report links, next steps
        Controls/
            AppListItem.xaml + .ps1       # Custom app row with color-coded install method badge
            ProgressPanel.xaml + .ps1     # Reusable progress display with animated bar
            LogViewer.xaml + .ps1         # Dark-themed scrolling log with auto-tail and line limit

    Reports/
        New-ManualInstallReport.ps1    # Generate HTML report for apps needing manual install
        New-CompletionReport.ps1       # Generate HTML completion summary with CSS pie charts
        Templates/
            ManualInstallReport.html   # HTML template with {{PLACEHOLDER}} markers
            CompletionReport.html      # HTML template with status badges and conic-gradient charts

    Tests/                         # Pester 5 suites; see Running Tests
```

---

## Architecture

### Data Flow

```
Source PC                          Transfer Medium                    Target PC
---------                          ---------------                    ---------
Registry ──┐                                                    ┌── WinGet install
WinGet ────┤                                                    ├── Choco install
Store ─────┼── Get-InstalledApps                                ├── Ninite install
ProgFiles ─┘   Resolve-InstallMethod                            ├── Store install
               │                                                ├── Vendor download
User Data ─────┤   ConvertTo-          USB Drive                │
Browsers ──────┼── MigrationManifest ──OneDrive ── Read-Manifest┤
WiFi/Print ────┤   Export-UserProfile  Google Drive Import-User ├── Restore files
Env Vars ──────┘   Export-Browser*     Custom       Import-*    ├── Restore browsers
                   Export-Settings*                              ├── Restore WiFi/print
                                                                ├── Merge env vars
                                                                └── HTML reports
```

### Class Model

Defined in `Core/Initialize-Environment.ps1`:

| Class | Purpose |
|---|---|
| `MigrationApp` | Discovered application with name, version, publisher, source, resolved install method, package ID, confidence score, and install status |
| `UserDataItem` | A profile folder or AppData subfolder with path, category, size, and export/import status |
| `BrowserProfile` | Browser profile with path, detected data flags (bookmarks, extensions, history), extension list, and status |
| `SystemSetting` | A system configuration item (WiFi profile, printer, drive mapping, env var) with category, data hashtable, and status |
| `MigrationManifest` | Top-level container: machine info, export date, arrays of all four item types, and metadata |
| `MigrationProgress` | Progress reporting: phase, current item, counts, percentage, and status message |

### Design Decisions

| Decision | Rationale |
|---|---|
| **PowerShell 5.1** (not 7+) | Ships with Windows 11. WPF `PresentationFramework` requires Windows PowerShell. |
| **Cloud via sync folder** (not API) | Avoids OAuth token management, app registration, and API rate limits. Relies on already-configured desktop sync clients. |
| **Robocopy** for file operations | Handles long paths (>260 chars), automatic retries, multi-threading, and structured exit codes. |
| **Fuzzy name matching** | Registry display names rarely match package manager IDs exactly. Levenshtein + Jaccard combination gives robust matching. |
| **Sequential app install, parallel to file restore** | Multiple concurrent MSI installs fail due to the Windows Installer mutex, so apps install one at a time. They run alongside the file restore because one is network-bound and the other disk-bound. |
| **Write packages in place** | Staging locally and then copying doubles the I/O and needs free space equal to the profile on the source disk. |
| **Receive mode instead of pushing to C$** | Workgroup PCs block remote admin access for local accounts. A share the target opens for itself works everywhere and needs no WinRM. |
| **One export and one import engine** | The GUI, CLI, backup and network paths call the same functions, so a fix lands everywhere at once. |
| **Individual failures don't abort** | A single failed app install or file copy should not prevent the rest of the migration. All errors are collected and shown in the completion report. |
| **No password export** | Browser password databases (`Login Data`, `logins.json`, `key4.db`) are never touched. This is a deliberate security decision. |
| **HTML reports** (no JS) | Self-contained, opens in any browser, no dependencies. CSS `conic-gradient` for pie charts. |

---

## Known Limitations

- **Passwords** are never migrated (browser passwords, Windows credentials). Users must re-enter these on the target machine.
- **Windows Settings** protection: Windows 10+ protects file association `UserChoice` entries with a hash that cannot be reproduced externally. File associations are restored on a best-effort basis.
- **Ninite free tier** does not provide granular exit codes or CLI control. Failures may not be precisely reported.
- **Store apps** that require specific hardware or account entitlements may fail to install via `winget --source msstore`.
- **Taskbar pins**: Windows 11 taskbar pin restoration is best-effort due to OS-level protections on the `Taskband` registry data.
- **Receive mode** needs administrator rights on the new PC, and a network that allows SMB between the two PCs. Guest networks with client isolation block it; use USB there.
- **Domain push** restores when the target user signs in. If that user is not a local administrator, app installs that need elevation fail and appear in the manual install report.
- **Encryption** is not applied to Receive-mode transfers; the package goes straight from one PC to the other.

---

## License

MIT -- see [LICENSE](LICENSE).
