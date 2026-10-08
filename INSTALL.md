# Win11Migrator - Installation Guide

## Quick Install

1. Download the latest release ZIP from [Releases](https://github.com/AuthorityGate/Win11Migrator/releases) or clone the repository:

   ```
   git clone https://github.com/AuthorityGate/Win11Migrator.git
   ```

2. Double-click `Win11Migrator.bat` to launch.

That's it. No build step, no dependencies to install. The tool runs directly from the folder.

---

## Detailed Setup

### Step 1: Get the Files

**Option A: Download ZIP**

1. Go to https://github.com/AuthorityGate/Win11Migrator
2. Click **Code** > **Download ZIP**
3. Extract the ZIP to any location (e.g. `C:\Win11Migrator`)

**Option B: Git Clone**

```powershell
git clone https://github.com/AuthorityGate/Win11Migrator.git
cd Win11Migrator
```

**Option C: Build from Source**

If you received the source and want to create a distributable package:

```powershell
.\Build.ps1
```

This creates `Build\Win11Migrator_v<version>.zip`, using the version in `Config\AppSettings.json`. Extract that ZIP on any target machine.

### Step 2: Verify Prerequisites

Open a PowerShell window and check your PowerShell version:

```powershell
$PSVersionTable.PSVersion
```

You need **5.1** or later. Windows 11 ships with 5.1 by default.

> **Important:** Use **Windows PowerShell** (the blue icon), not **PowerShell 7** (the black icon). The WPF GUI requires Windows PowerShell.

### Step 3: Run the Tool

**Method 1: Double-click the BAT file (recommended)**

- Double-click `Win11Migrator.bat`
- Click **Yes** on the UAC elevation prompt
- The wizard GUI opens

The `.bat` file automatically:
- Checks for administrator privileges
- Requests elevation if not already admin
- Sets the execution policy for the session
- Launches the PowerShell GUI

**Method 2: Run from PowerShell**

Open an **elevated** (Run as Administrator) PowerShell window:

```powershell
cd C:\path\to\Win11Migrator
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Win11Migrator.ps1
```

### Step 4: Verify WinGet (Recommended)

WinGet is the primary app installation method. It is pre-installed on Windows 11 22H2 and later. Verify it's available:

```powershell
winget --version
```

If not installed, get it from the [Microsoft Store](https://apps.microsoft.com/detail/9nblggh4nns1) (App Installer package) or from [GitHub](https://github.com/microsoft/winget-cli/releases).

---

## Both PCs on the Same Network (Fastest)

1. On the **target** PC, run `Win11Migrator.bat` as Administrator and select **Receive**. Note the pairing code it shows.
2. On the **source** PC, run `Win11Migrator.bat`, select **Export**, and on the transfer step choose **Another PC on this network**.
3. Pick the target PC from the list (or type its name or IP address), enter the pairing code and click **Connect**, then **Next**.
4. Leave both windows open. The target starts installing apps while files arrive, then restores everything on its own.

No USB drive, cloud account or WinRM is needed. If the source PC is turned off or loses the network mid-way, run the export again and choose **Resume**; files already sent are skipped.

---

## Running on the Source PC (Export)

1. Copy or clone the Win11Migrator folder to the source PC.
2. Run `Win11Migrator.bat` (or `.\Win11Migrator.ps1` from an elevated prompt).
3. Select **Export**.
4. The tool scans your PC. This takes 1-5 minutes depending on how many apps are installed.
5. Review and select the apps, data, and settings you want to migrate.
6. Choose a transfer method (another PC on the network, a domain PC's admin share, USB, OneDrive, Google Drive, a network share, or a custom folder).
7. Wait for the export to complete. The package is written straight to that destination; the export refuses to start if it would not fit.

The migration package is a folder named `Win11Migration_<COMPUTERNAME>_<timestamp>`. It contains a `manifest.json` and all exported data.

---

## Running on the Target PC (Import)

1. Copy or clone the Win11Migrator folder to the target PC.
2. Ensure the migration package is accessible (plug in the USB, wait for cloud sync, or map the network path).
3. Run `Win11Migrator.bat` as Administrator. **Admin is required on the target** for app installation.
4. Select **Import**.
5. Browse to the migration package folder (the one containing `manifest.json`), or select from auto-detected packages.
6. Wait for the import to complete. Apps install one at a time while your files are restored alongside them; this may take 10-30+ minutes depending on the number of apps.
7. Review the completion report and manual install guide.
8. **Restart your computer** to apply all changes.

---

## Chocolatey Auto-Bootstrap

If the migration package contains apps that should be installed via Chocolatey and Chocolatey is not already installed on the target PC, Win11Migrator will automatically install it during the import process. This requires:

- Administrator privileges (already required for import)
- Internet access

The bootstrap uses the official Chocolatey install script from `https://community.chocolatey.org/install.ps1`.

---

## File Locations

After running, Win11Migrator creates:

| Location | Contents |
|---|---|
| `Logs\` (next to Win11Migrator.ps1) | Timestamped log files for each session |
| `MigrationPackage\` (next to Win11Migrator.ps1) | Packages exported with no transfer target, encrypted packages while they are built, and import reports for read-only packages |
| Transfer destination (USB/cloud/share/folder) | `Win11Migrator\<package>` with a copy of the tool beside it |
| `C:\Win11MigratorIncoming\` on a receiving PC | Packages received over the network; the files are moved into the profile during the restore |

---

## Execution Policy

Win11Migrator requires PowerShell script execution to be allowed. The `.bat` launcher sets this automatically with:

```
-ExecutionPolicy Bypass
```

This applies only to the current process and does not change your system policy. If running manually, use:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Or if you prefer a persistent change for the current user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Firewall and Network

For **Receive mode**, the target PC adds two temporary inbound firewall rules, `Win11Migrator-Receive-SMB` (TCP 445) and `Win11Migrator-Receive-Discovery` (UDP 50717), and removes them when the transfer ends. If a third-party firewall blocks them, open those ports on the target while it receives, or type the target's IP address on the source instead of relying on discovery.

Win11Migrator needs internet access on the **target PC** for:

- `winget install` (downloads from Microsoft CDN and publisher sites)
- `choco install` (downloads from Chocolatey community repository)
- Ninite downloads (from ninite.com)
- Vendor direct downloads (various publisher URLs)

If behind a corporate firewall or proxy, ensure these domains are accessible:

- `*.dl.delivery.mp.microsoft.com` (WinGet)
- `community.chocolatey.org` (Chocolatey)
- `ninite.com` (Ninite)
- Various publisher download domains

---

## Troubleshooting

**"Running scripts is disabled on this system"**

Use the `.bat` launcher, which bypasses the execution policy for the session. Or run:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**GUI doesn't open**

Make sure you're using **Windows PowerShell 5.1** (not PowerShell 7). The WPF GUI requires the full .NET Framework that ships with Windows PowerShell. Check with:
```powershell
$PSVersionTable.PSEdition   # Should say "Desktop", not "Core"
```

**"Access denied" errors during import**

Run as Administrator. The `.bat` launcher handles this automatically.

**App installs fail**

- Check the log file in `Logs\` for the specific error
- Verify internet connectivity
- Some apps require manual installation (listed in the generated `ManualInstallReport.html`)
- WinGet source may need updating: `winget source update`

**Package not detected on target**

Make sure you're browsing to the folder that directly contains `manifest.json`, not a parent folder. For cloud transfers, ensure sync has completed before starting import.

**Large export taking too long**

- Reduce the number of selected data folders
- Exclude large folders (Videos, Downloads) if not needed
- The `RobocopyThreads` setting in `AppSettings.json` controls parallelism (default: 8)

---

## Uninstall

Win11Migrator does not install itself. To remove it, delete the `Win11Migrator` folder. Optionally clean up:

- `Logs\` directory
- `MigrationPackage\` directory
- Any migration packages on USB drives or cloud folders
