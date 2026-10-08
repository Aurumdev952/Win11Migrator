<#
========================================================================================================
    Title:          Win11Migrator - Main Entry Point
    Filename:       Win11Migrator.ps1
    Description:    Orchestrates the Windows 11 migration tool: loads modules, launches GUI or CLI mode.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Win11Migrator - Windows 11 Migration Tool
.DESCRIPTION
    Scans installed programs, settings, and user data on a source machine,
    packages everything for transfer, and reinstalls/restores on a target machine.
.PARAMETER CLI
    Run in CLI mode with a specific action. Valid actions:
    scan     - Scan this PC and display discovered apps, data, browsers, settings, profiles
    export   - Run a full export (scan + package creation)
    import   - Import/restore from a migration package
    validate - Validate a migration package (check manifest, verify file integrity)
    status   - Show migration status from registry
.PARAMETER Action
    The CLI action to perform (scan, export, import, validate, status).
.PARAMETER PackagePath
    Path to a migration package for import/validate, or output path for export/backup.
.PARAMETER Backup
    Run a headless backup of user profile and application profiles.
    Designed for integration with Windows Task Scheduler for weekly backups.
.PARAMETER ScheduleBackup
    Register a weekly scheduled task that runs -Backup automatically.
    Requires administrator privileges.
.EXAMPLE
    .\Win11Migrator.ps1 -CLI scan
    Scans this PC and reports all discovered items.
.EXAMPLE
    .\Win11Migrator.ps1 -CLI export -PackagePath "D:\Migration"
    Exports a full migration package to D:\Migration.
.EXAMPLE
    .\Win11Migrator.ps1 -CLI import -PackagePath "D:\Migration\Win11Migration_PC1_20260227"
    Imports and restores from the specified package.
.EXAMPLE
    .\Win11Migrator.ps1 -CLI validate -PackagePath "D:\Migration\Win11Migration_PC1_20260227"
    Validates the specified migration package.
.NOTES
    Run as Administrator for full functionality.
    Requires Windows PowerShell 5.1 (ships with Windows 11).
#>

[CmdletBinding()]
param(
    [ValidateSet('', 'scan', 'export', 'import', 'validate', 'status', 'diff', 'healthcheck', 'rollback')]
    [string]$CLI,
    [string]$PackagePath,
    [switch]$Backup,
    [string]$BackupPath,
    [switch]$ScheduleBackup,
    [switch]$Silent,
    [string]$Profile,
    [switch]$Incremental,
    [string]$NetworkTarget,
    [string]$TargetUser,
    [PSCredential]$TargetCredential,
    [string]$ComparePath,
    [switch]$Resume,
    [switch]$MoveFromPackage,
    [switch]$CheckForUpdates
)

$ErrorActionPreference = 'Stop'
$script:MigratorRoot = $PSScriptRoot
$script:MigratorVersion = [string](
    Get-Content (Join-Path $script:MigratorRoot 'Config\AppSettings.json') -Raw |
        ConvertFrom-Json
).Version

. "$script:MigratorRoot\Core\Invoke-SelfUpdate.ps1"
if ($CheckForUpdates) {
    Add-Type -AssemblyName PresentationFramework
    Invoke-Win11MigratorSelfUpdate -CurrentVersion ([version]$script:MigratorVersion)
    exit 0
}

# --- Load Core modules ---
. "$script:MigratorRoot\Core\Initialize-Environment.ps1"
. "$script:MigratorRoot\Core\Write-MigrationLog.ps1"
. "$script:MigratorRoot\Core\Test-AdminPrivilege.ps1"
. "$script:MigratorRoot\Core\Invoke-WithRetry.ps1"
. "$script:MigratorRoot\Core\Get-DiskSpaceEstimate.ps1"
. "$script:MigratorRoot\Core\ConvertTo-MigrationManifest.ps1"
. "$script:MigratorRoot\Core\Read-MigrationManifest.ps1"
. "$script:MigratorRoot\Core\Test-MigrationConfig.ps1"
. "$script:MigratorRoot\Core\Invoke-Robocopy.ps1"
. "$script:MigratorRoot\Core\Get-MigrationExclusions.ps1"
. "$script:MigratorRoot\Core\Invoke-MigrationExport.ps1"
. "$script:MigratorRoot\Core\Invoke-MigrationImport.ps1"

# --- Load App Discovery ---
Get-ChildItem "$script:MigratorRoot\Modules\AppDiscovery\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load User Data ---
Get-ChildItem "$script:MigratorRoot\Modules\UserData\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load Browser Profiles ---
Get-ChildItem "$script:MigratorRoot\Modules\BrowserProfiles\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load System Settings ---
Get-ChildItem "$script:MigratorRoot\Modules\SystemSettings\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load App Profiles ---
Get-ChildItem "$script:MigratorRoot\Modules\AppProfiles\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load App Installer ---
Get-ChildItem "$script:MigratorRoot\Modules\AppInstaller\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load Storage Targets ---
Get-ChildItem "$script:MigratorRoot\Modules\StorageTargets\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load USMT module (if directory exists) ---
$usmtModPath = Join-Path $script:MigratorRoot "Modules\USMT"
if (Test-Path $usmtModPath) {
    Get-ChildItem "$usmtModPath\*.ps1" | ForEach-Object { . $_.FullName }
}

# --- Load Network Transfer module (if directory exists) ---
$netModPath = Join-Path $script:MigratorRoot "Modules\NetworkTransfer"
if (Test-Path $netModPath) {
    Get-ChildItem "$netModPath\*.ps1" | ForEach-Object { . $_.FullName }
}

# --- Load Reports ---
Get-ChildItem "$script:MigratorRoot\Reports\*.ps1" | ForEach-Object { . $_.FullName }

# --- Load Core utilities (additional) ---
$coreExtras = @(
    'Get-OSMigrationContext', 'Convert-CrossOSSettings',
    'Protect-MigrationPackage', 'Unprotect-MigrationPackage', 'Test-PackageEncrypted',
    'Get-PackageFingerprint', 'Compare-PackageFingerprint', 'Compare-MigrationPackages',
    'New-RollbackSnapshot', 'Invoke-RollbackRestore', 'Invoke-HealthCheck'
)
foreach ($coreFn in $coreExtras) {
    $corePath = Join-Path $script:MigratorRoot "Core\$coreFn.ps1"
    if (Test-Path $corePath) { . $corePath }
}

# --- Initialize environment ---
$script:Config = Initialize-Environment -RootPath $script:MigratorRoot

# --- Silent mode ---
if ($Silent) {
    $script:SilentMode = $true
}

# --- Validate configuration ---
$configValidation = Test-MigrationConfig -RootPath $script:MigratorRoot
if (-not $configValidation.Valid) {
    foreach ($err in $configValidation.Errors) {
        Write-MigrationLog -Message "Config error: $err" -Level Error
    }
    if (-not $Silent) {
        Write-Host "ERROR: Configuration validation failed. Check log for details." -ForegroundColor Red
        foreach ($err in $configValidation.Errors) { Write-Host "  $err" -ForegroundColor Red }
    }
}
foreach ($warn in $configValidation.Warnings) {
    Write-MigrationLog -Message "Config warning: $warn" -Level Warning
}

# --- Load migration profile if specified ---
$script:MigrationProfile = $null
if ($Profile) {
    $profilePath = Join-Path $script:MigratorRoot "Config\MigrationProfiles\$Profile.json"
    if (Test-Path $profilePath) {
        try {
            $script:MigrationProfile = Get-Content $profilePath -Raw | ConvertFrom-Json
            Write-MigrationLog -Message "Migration profile loaded: $Profile ($($script:MigrationProfile.Description))" -Level Info
        } catch {
            Write-MigrationLog -Message "Failed to load migration profile '$Profile': $($_.Exception.Message)" -Level Warning
        }
    } else {
        Write-MigrationLog -Message "Migration profile not found: $profilePath" -Level Warning
        if (-not $Silent) {
            Write-Host "WARNING: Migration profile '$Profile' not found. Using defaults." -ForegroundColor Yellow
        }
    }
}

Write-MigrationLog -Message "Win11Migrator $script:MigratorVersion started" -Level Info

# --- Registry tracking ---
$regPath = 'HKCU:\SOFTWARE\AuthorityGate\Win11Migrator'
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name 'FirstRunDate' -Value (Get-Date).ToString('o')
}
Set-ItemProperty -Path $regPath -Name 'Version' -Value $script:MigratorVersion
Set-ItemProperty -Path $regPath -Name 'LastRunDate' -Value (Get-Date).ToString('o')
Set-ItemProperty -Path $regPath -Name 'InstallPath' -Value $script:MigratorRoot

# HKLM registry (only if admin)
$isAdmin = Test-AdminPrivilege
if ($isAdmin) {
    $regPathLM = 'HKLM:\SOFTWARE\AuthorityGate\Win11Migrator'
    if (-not (Test-Path $regPathLM)) {
        New-Item -Path $regPathLM -Force | Out-Null
    }
    Set-ItemProperty -Path $regPathLM -Name 'Version' -Value $script:MigratorVersion
    Set-ItemProperty -Path $regPathLM -Name 'InstallPath' -Value $script:MigratorRoot
    Set-ItemProperty -Path $regPathLM -Name 'LastRunDate' -Value (Get-Date).ToString('o')
} else {
    Write-MigrationLog -Message "Running without admin privileges. Some features may be limited." -Level Warning
}

# --- Schedule Backup Task ---
if ($ScheduleBackup) {
    if (-not $isAdmin) {
        Write-Host "ERROR: Scheduling a backup task requires administrator privileges." -ForegroundColor Red
        Write-Host "Please run Win11Migrator.bat as Administrator and try again." -ForegroundColor Yellow
        exit 1
    }
    $taskName = 'Win11Migrator Weekly Backup'
    $scriptPath = Join-Path $script:MigratorRoot 'Win11Migrator.ps1'
    $outputPath = if ($BackupPath) { $BackupPath } else { $script:Config.PackagePath }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Backup -BackupPath `"$outputPath`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '2:00AM'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
            -Description 'Weekly backup of user profile and application settings via Win11Migrator' -Force | Out-Null
        Write-Host "Scheduled task '$taskName' registered successfully." -ForegroundColor Green
        Write-Host "  Runs every Sunday at 2:00 AM" -ForegroundColor Cyan
        Write-Host "  Backup path: $outputPath" -ForegroundColor Cyan
        Set-ItemProperty -Path $regPath -Name 'ScheduledBackupEnabled' -Value 1
        Set-ItemProperty -Path $regPath -Name 'ScheduledBackupPath' -Value $outputPath
    } catch {
        Write-Host "ERROR: Failed to register scheduled task: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# --- Headless Backup Mode ---
if ($Backup) {
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  Win11Migrator - Profile Backup Mode" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    $outputDir = if ($BackupPath) { $BackupPath } else { $script:Config.PackagePath }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $pkgName = "Win11Backup_$($env:COMPUTERNAME)_$timestamp"
    $pkgPath = Join-Path $outputDir $pkgName
    New-Item -Path $pkgPath -ItemType Directory -Force | Out-Null

    Write-Host "[1/5] Scanning installed applications..." -ForegroundColor Yellow
    $apps = Get-InstalledApps
    Write-Host "  Found $($apps.Count) applications" -ForegroundColor Green

    Write-Host "[2/5] Detecting user data folders..." -ForegroundColor Yellow
    $userData = @(Get-DefaultUserDataItems -SkipCloudSynced)
    Write-Host "  Found $($userData.Count) user data folders" -ForegroundColor Green

    Write-Host "[3/5] Exporting user data..." -ForegroundColor Yellow
    $dataDir = Join-Path $pkgPath "UserData"
    New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    $exportData = @($userData | Where-Object { -not $_.SkipCloudSync })
    $skippedCloud = @($userData | Where-Object { $_.SkipCloudSync })
    if ($skippedCloud.Count -gt 0) {
        Write-Host "  Skipping $($skippedCloud.Count) cloud-synced folder(s) (will re-sync)" -ForegroundColor Cyan
        foreach ($sk in $skippedCloud) { $sk.ExportStatus = 'Skipped' }
    }
    try {
        if ($Incremental) {
            # Incremental backup: only copy changed files since last backup
            $lastBackupPath = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\AuthorityGate\Win11Migrator' -Name 'LastBackupPath' -ErrorAction SilentlyContinue).LastBackupPath
            if ($lastBackupPath -and (Test-Path (Join-Path $lastBackupPath "fingerprint.json"))) {
                Write-Host "  Incremental mode: comparing against $lastBackupPath" -ForegroundColor Cyan
                Export-IncrementalProfile -Items $exportData -OutputDirectory $dataDir -PreviousPackagePath $lastBackupPath | Out-Null
            } else {
                Write-Host "  No previous backup found, performing full backup" -ForegroundColor Yellow
                Export-UserProfile -Items $exportData -OutputDirectory $dataDir | Out-Null
            }
        } else {
            Export-UserProfile -Items $exportData -OutputDirectory $dataDir | Out-Null
        }
        Write-Host "  User data exported" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "[4/5] Detecting and exporting application profiles..." -ForegroundColor Yellow
    $appProfiles = @(Get-DetectedAppProfiles -InstalledApps $apps)
    Write-Host "  Detected $($appProfiles.Count) application profiles" -ForegroundColor Green
    if ($appProfiles.Count -gt 0) {
        $profilesDir = Join-Path $pkgPath "AppProfiles"
        New-Item -Path $profilesDir -ItemType Directory -Force | Out-Null
        $exported = Export-AppProfiles -Profiles $appProfiles -OutputPath $profilesDir
        Write-Host "  Exported $exported application profiles" -ForegroundColor Green
    }

    Write-Host "[5/5] Writing backup manifest..." -ForegroundColor Yellow
    ConvertTo-MigrationManifest -OutputPath $pkgPath `
        -Apps $apps `
        -UserData $userData `
        -AppProfiles $appProfiles `
        -Metadata @{ BackupMode = $true; BackupDate = (Get-Date).ToString('o'); Incremental = [bool]$Incremental }
    Write-Host "  Manifest written" -ForegroundColor Green

    # Generate fingerprint for incremental backup support
    try {
        $fingerprint = Get-PackageFingerprint -PackagePath $pkgPath
        $fingerprint | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $pkgPath "fingerprint.json") -Encoding UTF8
        Write-Host "  Package fingerprint generated" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Fingerprint generation failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Update registry with last backup info
    Set-ItemProperty -Path $regPath -Name 'LastBackupDate' -Value (Get-Date).ToString('o')
    Set-ItemProperty -Path $regPath -Name 'LastBackupPath' -Value $pkgPath

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Backup complete!" -ForegroundColor Green
    Write-Host "  Package: $pkgPath" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Green

    Write-MigrationLog -Message "Backup completed: $pkgPath" -Level Success
    exit 0
}

# --- Launch GUI or CLI ---
if ($CLI) {
    Write-Host ""
    Write-Host "  Win11Migrator $script:MigratorVersion - CLI Mode" -ForegroundColor Cyan
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host ""

    switch ($CLI) {
        # =============================================
        # CLI: SCAN - Discover all items on this PC
        # =============================================
        'scan' {
            Write-MigrationLog -Message "CLI scan started" -Level Info

            # 1. Applications
            Write-Host "[1/5] Scanning installed applications..." -ForegroundColor Yellow
            $apps = Get-InstalledApps
            # Apply exclusion filters
            $excludedPatterns = @()
            $excludedPath = Join-Path $script:MigratorRoot "Config\ExcludedApps.json"
            if (Test-Path $excludedPath) {
                try { $excludedPatterns = Get-Content $excludedPath -Raw | ConvertFrom-Json } catch {}
            }
            $hardwarePublishers = @(
                'NVIDIA Corporation', 'Advanced Micro Devices*', 'Intel Corporation', 'Intel(R) Corporation',
                'Realtek Semiconductor*', 'Realtek', 'Qualcomm*', 'Broadcom*', 'Synaptics*',
                'ELAN Microelectronics*', 'Alps Electric*', 'Conexant*', 'IDT*', 'Marvell*', 'MediaTek*', 'Tobii*'
            )
            $filteredApps = @()
            $excludedCount = 0
            foreach ($app in $apps) {
                $name = $app.Name
                $publisher = if ($app.Publisher) { $app.Publisher } else { '' }
                $excluded = $false
                foreach ($pattern in $excludedPatterns) { if ($name -like $pattern) { $excluded = $true; break } }
                if (-not $excluded) { foreach ($hwPub in $hardwarePublishers) { if ($publisher -like $hwPub) { $excluded = $true; break } } }
                if ($excluded) { $excludedCount++ } else { $filteredApps += $app }
            }
            Write-Host "  Found $($filteredApps.Count) applications ($excludedCount drivers/hardware excluded)" -ForegroundColor Green

            # Resolve install methods
            Write-Host "[2/5] Resolving install methods..." -ForegroundColor Yellow
            $autoCount = 0; $manualCount = 0
            foreach ($app in $filteredApps) {
                $normName = Get-NormalizedAppName -Name $app.Name
                # Try local catalogs first
                $ninite = Search-NinitePackage -AppName $normName
                if ($ninite.Found) { $app.InstallMethod = 'Ninite'; $app.PackageId = $ninite.PackageId; $autoCount++; continue }
                $store = Search-StorePackage -AppName $normName
                if ($store.Found) { $app.InstallMethod = 'Store'; $app.PackageId = $store.PackageId; $autoCount++; continue }
                $vendor = Search-VendorDownload -AppName $normName
                if ($vendor.Found) { $app.InstallMethod = 'VendorDownload'; $app.DownloadUrl = $vendor.DownloadUrl; $autoCount++; continue }
                $manualCount++
            }
            # Try winget for remaining
            $wingetAvailable = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
            if ($wingetAvailable) {
                $unresolved = @($filteredApps | Where-Object { -not $_.InstallMethod })
                Write-Host "  Checking winget for $($unresolved.Count) unresolved apps..." -ForegroundColor DarkGray
                foreach ($app in $unresolved) {
                    try {
                        $normName = Get-NormalizedAppName -Name $app.Name
                        $searchResult = Search-WingetPackage -AppName $normName
                        if ($searchResult) {
                            $app.InstallMethod = 'Winget'
                            $app.PackageId = $searchResult.PackageId
                            $app.MatchConfidence = $searchResult.Confidence
                            $autoCount++
                            $manualCount--
                        }
                    } catch {}
                }
            }
            $autoPct = if ($filteredApps.Count -gt 0) { [Math]::Round(($autoCount / $filteredApps.Count) * 100, 1) } else { 0 }
            Write-Host "  Auto-install: $autoCount ($autoPct%) | Manual: $manualCount" -ForegroundColor Green

            # 2. User Data
            Write-Host "[3/5] Detecting user data folders..." -ForegroundColor Yellow
            $profilePaths = Get-UserProfilePaths
            $cloudFolders = Find-CloudSyncFolders
            $userDataFolders = @()
            foreach ($folder in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'Favorites')) {
                $folderPath = $profilePaths[$folder]
                if (-not $folderPath) { $folderPath = Join-Path $env:USERPROFILE $folder }
                if (Test-Path $folderPath) {
                    $count = @(Get-ChildItem $folderPath -Force -ErrorAction SilentlyContinue).Count
                    $isOneDrive = ($folderPath -match 'OneDrive')
                    $isGoogleDrive = $false
                    if ($cloudFolders.GoogleDriveAvailable -and $cloudFolders.GoogleDrivePath) {
                        $gdNorm = $cloudFolders.GoogleDrivePath.TrimEnd('\')
                        $isGoogleDrive = ($folderPath -like "$gdNorm\*" -or $folderPath -eq $gdNorm)
                    }
                    $cloudProvider = if ($isOneDrive) { 'OneDrive' } elseif ($isGoogleDrive) { 'GoogleDrive' } else { '' }
                    $label = if ($isOneDrive) { "$folder (OneDrive)" } elseif ($isGoogleDrive) { "$folder (Google Drive)" } else { $folder }
                    Write-Host "    $label - $count items ($folderPath)" -ForegroundColor DarkGray
                    $userDataFolders += @{ Name = $folder; Path = $folderPath; Count = $count; OneDrive = $isOneDrive; CloudProvider = $cloudProvider }
                }
            }
            Write-Host "  Found $($userDataFolders.Count) user data folders" -ForegroundColor Green

            # 3. Browser Profiles
            Write-Host "[4/5] Detecting browser profiles..." -ForegroundColor Yellow
            $browsers = @()
            $localAppData = $env:LOCALAPPDATA; $appData = $env:APPDATA
            $browserDefs = @(
                @{ Name = 'Chrome'; Path = Join-Path $localAppData "Google\Chrome\User Data"; Filter = $true }
                @{ Name = 'Edge'; Path = Join-Path $localAppData "Microsoft\Edge\User Data"; Filter = $true }
                @{ Name = 'Brave'; Path = Join-Path $localAppData "BraveSoftware\Brave-Browser\User Data"; Filter = $true }
                @{ Name = 'Firefox'; Path = Join-Path $appData "Mozilla\Firefox\Profiles"; Filter = $false }
            )
            foreach ($def in $browserDefs) {
                if (Test-Path $def.Path) {
                    if ($def.Filter) {
                        $profiles = @(Get-ChildItem $def.Path -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' })
                    } else {
                        $profiles = @(Get-ChildItem $def.Path -Directory -ErrorAction SilentlyContinue)
                    }
                    foreach ($p in $profiles) {
                        $browsers += @{ Browser = $def.Name; ProfileName = $p.Name; Path = $p.FullName }
                        Write-Host "    $($def.Name) - $($p.Name)" -ForegroundColor DarkGray
                    }
                }
            }
            Write-Host "  Found $($browsers.Count) browser profiles" -ForegroundColor Green

            # 4. System Settings
            Write-Host "[5/5] Detecting system settings..." -ForegroundColor Yellow
            try {
                $wifiOutput = netsh wlan show profiles 2>$null
                $wifiProfiles = @($wifiOutput | Select-String 'All User Profile\s*:\s*(.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
                if ($wifiProfiles.Count -gt 0) { Write-Host "    WiFi profiles: $($wifiProfiles.Count)" -ForegroundColor DarkGray }
            } catch { $wifiProfiles = @() }
            try {
                $printers = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Microsoft|OneNote|Fax' })
                if ($printers.Count -gt 0) { Write-Host "    Printers: $($printers.Count)" -ForegroundColor DarkGray }
            } catch { $printers = @() }
            try {
                $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.DisplayRoot -and $_.DisplayRoot.StartsWith('\\') })
                if ($drives.Count -gt 0) { Write-Host "    Mapped drives: $($drives.Count)" -ForegroundColor DarkGray }
            } catch { $drives = @() }
            $userEnv = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::User)
            Write-Host "    User env vars: $($userEnv.Count)" -ForegroundColor DarkGray

            # App Profiles
            $appProfiles = @(Get-DetectedAppProfiles -InstalledApps $filteredApps)
            if ($appProfiles.Count -gt 0) {
                Write-Host "  Application profiles: $($appProfiles.Count) detected" -ForegroundColor Green
                foreach ($p in $appProfiles) {
                    Write-Host "    $($p.Name) [$($p.Category)] - $($p.FileCount) files, $($p.RegistryCount) registry" -ForegroundColor DarkGray
                }
            }

            # Summary
            Write-Host ""
            Write-Host "  ========== SCAN SUMMARY ==========" -ForegroundColor Cyan
            Write-Host "  Applications:       $($filteredApps.Count) ($autoCount auto, $manualCount manual, $excludedCount excluded)" -ForegroundColor White
            Write-Host "  User Data Folders:  $($userDataFolders.Count)" -ForegroundColor White
            Write-Host "  Browser Profiles:   $($browsers.Count)" -ForegroundColor White
            Write-Host "  WiFi Profiles:      $($wifiProfiles.Count)" -ForegroundColor White
            Write-Host "  Printers:           $($printers.Count)" -ForegroundColor White
            Write-Host "  Mapped Drives:      $($drives.Count)" -ForegroundColor White
            Write-Host "  Env Variables:      $($userEnv.Count)" -ForegroundColor White
            Write-Host "  App Profiles:       $($appProfiles.Count)" -ForegroundColor White
            Write-Host "  ===================================" -ForegroundColor Cyan
            Write-MigrationLog -Message "CLI scan completed" -Level Success
        }

        # =============================================
        # CLI: EXPORT - Full export to package
        # =============================================
        'export' {
            Write-Host "[1/4] Scanning applications..." -ForegroundColor Yellow
            $apps = @(Get-InstalledApps)
            Write-Host "  Found $($apps.Count) applications" -ForegroundColor Green

            Write-Host "[2/4] Detecting user data and browser profiles..." -ForegroundColor Yellow
            $exclusions = Get-MigrationExclusions
            $userData = @(Get-DefaultUserDataItems -SkipCloudSynced)
            foreach ($item in $userData | Where-Object { -not $_.SkipCloudSync }) {
                $item.SizeBytes = (Measure-RobocopySource -Source $item.SourcePath -Exclusions $exclusions).Bytes
                Write-Host ("  {0,-10} {1,8:N1} GB" -f $item.Category, ($item.SizeBytes / 1GB)) -ForegroundColor DarkGray
            }
            foreach ($cf in $userData | Where-Object { $_.SkipCloudSync }) {
                Write-Host "  $($cf.Category) is synced by $($cf.CloudProvider); it will re-sync on the new PC" -ForegroundColor DarkCyan
            }

            $browsers = @()
            $browserDefs = @(
                @{ Name = 'Chrome';  Path = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"; Filter = $true }
                @{ Name = 'Edge';    Path = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"; Filter = $true }
                @{ Name = 'Brave';   Path = Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data"; Filter = $true }
                @{ Name = 'Firefox'; Path = Join-Path $env:APPDATA "Mozilla\Firefox\Profiles"; Filter = $false }
            )
            foreach ($def in $browserDefs) {
                if (-not (Test-Path $def.Path)) { continue }
                $profiles = @(Get-ChildItem $def.Path -Directory -ErrorAction SilentlyContinue |
                    Where-Object { -not $def.Filter -or $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' })
                foreach ($p in $profiles) {
                    $bp = [BrowserProfile]::new()
                    $bp.Browser = $def.Name
                    $bp.ProfileName = $p.Name
                    $bp.ProfilePath = $p.FullName
                    $bp.Selected = $true
                    $browsers += $bp
                }
            }
            $appProfiles = @(Get-DetectedAppProfiles -InstalledApps $apps)
            Write-Host "  $($userData.Count) folders, $($browsers.Count) browser profiles, $($appProfiles.Count) app profiles" -ForegroundColor Green

            Write-Host "[3/4] Writing the migration package..." -ForegroundColor Yellow
            $selection = @{
                Apps            = $apps
                UserData        = $userData
                BrowserProfiles = $browsers
                AppProfiles     = $appProfiles
                SettingsFlags   = Get-AllSettingsFlags
                IncludeAppData  = $true
                Exclusions      = $exclusions
            }
            $requiredBytes = [long](($userData | Where-Object { -not $_.SkipCloudSync } | Measure-Object -Property SizeBytes -Sum).Sum)
            $outputRoot = if ($PackagePath) { $PackagePath } else { $script:Config.PackagePath }
            $progress = [hashtable]::Synchronized(@{
                Log  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                Echo = -not $Silent
            })
            try {
                $destination = Resolve-ExportDestination -StorageTarget $null -RequiredBytes $requiredBytes -LocalPackageRoot $outputRoot
                $result = Invoke-MigrationExportToDestination -Destination $destination -Selection $selection -Progress $progress -Resume:$Resume
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
            $pkgPath = $result.PackagePath
            foreach ($err in $result.Errors) { Write-Host "  WARNING: $err" -ForegroundColor Yellow }

            # Direct network transfer if -NetworkTarget specified
            if ($NetworkTarget) {
                Write-Host ""
                Write-Host "  Pushing to network target: $NetworkTarget" -ForegroundColor Cyan
                if (-not $TargetCredential) {
                    Write-Host "ERROR: -TargetCredential is required for network transfer." -ForegroundColor Red
                    Write-Host "Usage: -NetworkTarget 'PC2' -TargetUser 'user' -TargetCredential (Get-Credential)" -ForegroundColor Yellow
                    exit 1
                }
                $targetUserName = if ($TargetUser) { $TargetUser } else { $env:USERNAME }
                try {
                    $state = @{
                        Apps = $apps
                        UserData = $result.UserData
                        BrowserProfiles = $browsers
                        SystemSettings = $result.SystemSettings
                        AppProfiles = $appProfiles
                        PackagePath = $pkgPath
                    }
                    Push-MigrationDirect -ComputerName $NetworkTarget -Credential $TargetCredential `
                        -TargetUserName $targetUserName -State $state
                    Write-Host "  Network transfer complete!" -ForegroundColor Green
                } catch {
                    Write-Host "  Network transfer failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            Write-Host "[4/4] Done" -ForegroundColor Yellow
            if (-not $Silent) {
                Write-Host ""
                Write-Host "  Export complete: $pkgPath" -ForegroundColor Green
            }
            Write-MigrationLog -Message "CLI export completed: $pkgPath" -Level Success

            if ($Silent) {
                @{
                    success     = ($result.Errors.Count -eq 0)
                    action      = 'export'
                    packagePath = $pkgPath
                    appCount    = $apps.Count
                    dataCount   = @($result.UserData).Count
                    errors      = @($result.Errors)
                    timestamp   = (Get-Date).ToString('o')
                } | ConvertTo-Json | Set-Content (Join-Path $pkgPath "migration-result.json") -Encoding UTF8
                exit 0
            }
        }

        # =============================================
        # CLI: IMPORT - Restore from package
        # =============================================
        'import' {
            if (-not $PackagePath) {
                Write-Host "ERROR: -PackagePath is required for import." -ForegroundColor Red
                Write-Host "Usage: .\Win11Migrator.ps1 -CLI import -PackagePath 'C:\path\to\package'" -ForegroundColor Yellow
                exit 1
            }
            if (-not (Test-Path $PackagePath)) {
                Write-Host "ERROR: Package path not found: $PackagePath" -ForegroundColor Red
                exit 1
            }
            $manifestPath = Join-Path $PackagePath "manifest.json"
            if (-not (Test-Path $manifestPath)) {
                Write-Host "ERROR: No manifest.json found in $PackagePath" -ForegroundColor Red
                exit 1
            }

            Write-MigrationLog -Message "CLI import started from $PackagePath" -Level Info
            $manifest = Read-MigrationManifest -ManifestPath (Join-Path $PackagePath "manifest.json")
            Write-Host "  Package from: $($manifest.SourceComputerName) ($($manifest.ExportDate))" -ForegroundColor Cyan
            Write-Host "  Apps: $($manifest.Apps.Count) | UserData: $($manifest.UserData.Count) | Browsers: $($manifest.BrowserProfiles.Count)" -ForegroundColor Cyan
            Write-Host ""

            $progress = [hashtable]::Synchronized(@{
                Log  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                Echo = -not $Silent
            })
            $result = Invoke-MigrationImport -PackagePath $PackagePath -Manifest $manifest -Progress $progress -MoveFromPackage:$MoveFromPackage
            foreach ($err in $result.Errors) { Write-Host "  WARNING: $err" -ForegroundColor Yellow }

            try {
                @{
                    phase     = 'complete'
                    percent   = 100
                    succeeded = $result.Succeeded
                    failed    = $result.Failed
                    errors    = $result.Errors
                    timestamp = (Get-Date).ToString('o')
                } | ConvertTo-Json | Set-Content (Join-Path $result.WorkPath "progress.json") -Encoding UTF8
            } catch {}

            if (-not $Silent) {
                Write-Host ""
                Write-Host "  Import complete: $($result.Succeeded) restored, $($result.Failed) failed" -ForegroundColor Green
                if ($result.CompletionReportPath) { Write-Host "  Report: $($result.CompletionReportPath)" -ForegroundColor Cyan }
            }
            Write-MigrationLog -Message "CLI import completed from $PackagePath" -Level Success

            if ($Silent) {
                $exitCode = if ($result.Failed -gt 0) { 1 } else { 0 }  # 1=partial, 0=success
                @{
                    success   = ($result.Failed -eq 0)
                    action    = 'import'
                    succeeded = $result.Succeeded
                    failed    = $result.Failed
                    errors    = $result.Errors
                    timestamp = (Get-Date).ToString('o')
                } | ConvertTo-Json | Set-Content (Join-Path $result.WorkPath "migration-result.json") -Encoding UTF8
                exit $exitCode
            }
        }

        # =============================================
        # CLI: VALIDATE - Verify package integrity
        # =============================================
        'validate' {
            if (-not $PackagePath) {
                Write-Host "ERROR: -PackagePath is required for validate." -ForegroundColor Red
                Write-Host "Usage: .\Win11Migrator.ps1 -CLI validate -PackagePath 'C:\path\to\package'" -ForegroundColor Yellow
                exit 1
            }
            if (-not (Test-Path $PackagePath)) {
                Write-Host "ERROR: Package path not found: $PackagePath" -ForegroundColor Red
                exit 1
            }

            Write-MigrationLog -Message "CLI validate started for $PackagePath" -Level Info
            $errors = 0; $warnings = 0; $passed = 0

            # Check manifest
            $manifestPath = Join-Path $PackagePath "manifest.json"
            if (Test-Path $manifestPath) {
                Write-Host "  [PASS] manifest.json exists" -ForegroundColor Green; $passed++
                try {
                    $manifest = Read-MigrationManifest -ManifestPath (Join-Path $PackagePath "manifest.json")
                    Write-Host "  [PASS] manifest.json is valid JSON" -ForegroundColor Green; $passed++
                    Write-Host "         Source: $($manifest.SourceComputerName) | Date: $($manifest.ExportDate)" -ForegroundColor DarkGray
                    Write-Host "         Apps: $($manifest.Apps.Count) | UserData: $($manifest.UserData.Count) | Browsers: $($manifest.BrowserProfiles.Count)" -ForegroundColor DarkGray
                    Write-Host "         Settings: $($manifest.SystemSettings.Count) | AppProfiles: $($manifest.AppProfiles.Count)" -ForegroundColor DarkGray
                } catch {
                    Write-Host "  [FAIL] manifest.json parse error: $($_.Exception.Message)" -ForegroundColor Red; $errors++
                    Write-Host ""; Write-Host "  Validation aborted - cannot continue without valid manifest." -ForegroundColor Red
                    exit 1
                }
            } else {
                Write-Host "  [FAIL] manifest.json not found" -ForegroundColor Red; $errors++
                exit 1
            }

            # Check directories
            foreach ($dir in @('UserData', 'BrowserProfiles', 'SystemSettings', 'AppProfiles', 'AppData')) {
                $dirPath = Join-Path $PackagePath $dir
                if (Test-Path $dirPath) {
                    $fileCount = @(Get-ChildItem $dirPath -Recurse -File -ErrorAction SilentlyContinue).Count
                    Write-Host "  [PASS] $dir/ exists ($fileCount files)" -ForegroundColor Green; $passed++
                } else {
                    Write-Host "  [WARN] $dir/ not found" -ForegroundColor Yellow; $warnings++
                }
            }

            # Validate user data items
            if ($manifest.UserData.Count -gt 0) {
                $dataDir = Join-Path $PackagePath "UserData"
                foreach ($item in $manifest.UserData) {
                    $relPath = if ($item.RelativePath) { $item.RelativePath } else { $item.Category }
                    $itemPath = Join-Path $dataDir $relPath
                    if (Test-Path $itemPath) {
                        $passed++
                    } else {
                        Write-Host "  [WARN] UserData missing: $relPath" -ForegroundColor Yellow; $warnings++
                    }
                }
                Write-Host "  [INFO] UserData items validated: $($manifest.UserData.Count)" -ForegroundColor Cyan
            }

            # Validate browser profiles
            if ($manifest.BrowserProfiles.Count -gt 0) {
                $browserDir = Join-Path $PackagePath "BrowserProfiles"
                foreach ($profile in $manifest.BrowserProfiles) {
                    $profileDir = Join-Path $browserDir "$($profile.Browser)_$($profile.ProfileName)"
                    if (Test-Path $profileDir) {
                        $passed++
                    } else {
                        Write-Host "  [WARN] Browser profile missing: $($profile.Browser) - $($profile.ProfileName)" -ForegroundColor Yellow; $warnings++
                    }
                }
                Write-Host "  [INFO] Browser profiles validated: $($manifest.BrowserProfiles.Count)" -ForegroundColor Cyan
            }

            # Validate app profiles
            if ($manifest.AppProfiles.Count -gt 0) {
                $profilesDir = Join-Path $PackagePath "AppProfiles"
                foreach ($profile in $manifest.AppProfiles) {
                    $profileDir = Join-Path $profilesDir ($profile.Name -replace '[\\/:*?"<>|]', '_')
                    if (Test-Path $profileDir) {
                        $passed++
                    } else {
                        Write-Host "  [WARN] App profile missing: $($profile.Name)" -ForegroundColor Yellow; $warnings++
                    }
                }
                Write-Host "  [INFO] App profiles validated: $($manifest.AppProfiles.Count)" -ForegroundColor Cyan
            }

            # Validate apps have install methods
            $autoApps = @($manifest.Apps | Where-Object { $_.InstallMethod -and $_.InstallMethod -ne 'Manual' }).Count
            $manualApps = @($manifest.Apps | Where-Object { -not $_.InstallMethod -or $_.InstallMethod -eq 'Manual' }).Count
            Write-Host "  [INFO] Apps: $autoApps auto-install, $manualApps manual" -ForegroundColor Cyan

            # Package size
            $totalSize = (Get-ChildItem $PackagePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $sizeGB = [Math]::Round($totalSize / 1GB, 2)
            $sizeMB = [Math]::Round($totalSize / 1MB, 1)
            $sizeLabel = if ($sizeGB -ge 1) { "$sizeGB GB" } else { "$sizeMB MB" }
            Write-Host "  [INFO] Total package size: $sizeLabel" -ForegroundColor Cyan

            # Summary
            Write-Host ""
            if ($errors -eq 0) {
                Write-Host "  VALIDATION PASSED ($passed checks passed, $warnings warnings)" -ForegroundColor Green
            } else {
                Write-Host "  VALIDATION FAILED ($errors errors, $warnings warnings, $passed passed)" -ForegroundColor Red
            }
            Write-MigrationLog -Message "CLI validate completed: $passed passed, $errors errors, $warnings warnings" -Level Success
        }

        # =============================================
        # CLI: STATUS - Show migration registry info
        # =============================================
        'status' {
            Write-Host "  Win11Migrator Registry Status" -ForegroundColor Cyan
            Write-Host "  =============================" -ForegroundColor Cyan
            $regPath = 'HKCU:\SOFTWARE\AuthorityGate\Win11Migrator'
            if (Test-Path $regPath) {
                $reg = Get-ItemProperty $regPath
                Write-Host "  Version:          $($reg.Version)" -ForegroundColor White
                Write-Host "  Install Path:     $($reg.InstallPath)" -ForegroundColor White
                Write-Host "  First Run:        $($reg.FirstRunDate)" -ForegroundColor White
                Write-Host "  Last Run:         $($reg.LastRunDate)" -ForegroundColor White
                if ($reg.LastBackupDate) {
                    Write-Host "  Last Backup:      $($reg.LastBackupDate)" -ForegroundColor White
                    Write-Host "  Backup Path:      $($reg.LastBackupPath)" -ForegroundColor White
                }
                if ($reg.ScheduledBackupEnabled) {
                    Write-Host "  Scheduled Backup: Enabled" -ForegroundColor Green
                    Write-Host "  Scheduled Path:   $($reg.ScheduledBackupPath)" -ForegroundColor White
                }
            } else {
                Write-Host "  No registry data found. Run Win11Migrator at least once." -ForegroundColor Yellow
            }

            # HKLM (if accessible)
            $regPathLM = 'HKLM:\SOFTWARE\AuthorityGate\Win11Migrator'
            if (Test-Path $regPathLM) {
                $regLM = Get-ItemProperty $regPathLM
                Write-Host ""
                Write-Host "  Machine-Level Registry (HKLM):" -ForegroundColor Cyan
                Write-Host "  Version:          $($regLM.Version)" -ForegroundColor White
                Write-Host "  Install Path:     $($regLM.InstallPath)" -ForegroundColor White
                Write-Host "  Last Run:         $($regLM.LastRunDate)" -ForegroundColor White
            }
        }

        # =============================================
        # CLI: DIFF - Compare two migration packages
        # =============================================
        'diff' {
            if (-not $PackagePath -or -not $ComparePath) {
                Write-Host "ERROR: -PackagePath and -ComparePath are required for diff." -ForegroundColor Red
                Write-Host "Usage: .\Win11Migrator.ps1 -CLI diff -PackagePath 'path1' -ComparePath 'path2'" -ForegroundColor Yellow
                exit 1
            }
            Write-MigrationLog -Message "CLI diff: comparing $PackagePath vs $ComparePath" -Level Info
            try {
                $diffResult = Compare-MigrationPackages -PackagePath1 $PackagePath -PackagePath2 $ComparePath
                Write-Host "  Package 1: $($diffResult.Package1.ComputerName) ($($diffResult.Package1.ExportDate))" -ForegroundColor Cyan
                Write-Host "  Package 2: $($diffResult.Package2.ComputerName) ($($diffResult.Package2.ExportDate))" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Apps: +$($diffResult.Apps.Added.Count) added, -$($diffResult.Apps.Removed.Count) removed, $($diffResult.Apps.Common) common" -ForegroundColor White
                Write-Host "  UserData: +$($diffResult.UserData.Added.Count) added, -$($diffResult.UserData.Removed.Count) removed" -ForegroundColor White
                Write-Host "  Browsers: +$($diffResult.BrowserProfiles.Added.Count) added, -$($diffResult.BrowserProfiles.Removed.Count) removed" -ForegroundColor White
                Write-Host "  Settings: +$($diffResult.SystemSettings.Added.Count) added, -$($diffResult.SystemSettings.Removed.Count) removed" -ForegroundColor White
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        }

        # =============================================
        # CLI: HEALTHCHECK - Post-migration verification
        # =============================================
        'healthcheck' {
            if (-not $PackagePath) {
                Write-Host "ERROR: -PackagePath is required for healthcheck." -ForegroundColor Red
                exit 1
            }
            $manifestPath = Join-Path $PackagePath "manifest.json"
            if (-not (Test-Path $manifestPath)) {
                Write-Host "ERROR: No manifest.json found in $PackagePath" -ForegroundColor Red
                exit 1
            }
            Write-MigrationLog -Message "CLI healthcheck from $PackagePath" -Level Info
            $manifest = Read-MigrationManifest -ManifestPath $manifestPath
            $healthResult = Invoke-HealthCheck -Manifest $manifest
            Write-Host ""
            Write-Host "  Post-Migration Health Check" -ForegroundColor Cyan
            Write-Host "  ===========================" -ForegroundColor Cyan
            Write-Host "  Score: $([Math]::Round($healthResult.Score, 1))%" -ForegroundColor $(if ($healthResult.Score -ge 80) { 'Green' } elseif ($healthResult.Score -ge 50) { 'Yellow' } else { 'Red' })
            Write-Host "  Passed: $($healthResult.Passed) | Failed: $($healthResult.Failed) | Warnings: $($healthResult.Warnings)" -ForegroundColor White
            Write-Host ""
            foreach ($check in $healthResult.Checks) {
                $icon = switch ($check.Status) { 'Pass' { '[PASS]' }; 'Fail' { '[FAIL]' }; 'Warning' { '[WARN]' }; default { '[----]' } }
                $color = switch ($check.Status) { 'Pass' { 'Green' }; 'Fail' { 'Red' }; 'Warning' { 'Yellow' }; default { 'Gray' } }
                Write-Host "  $icon $($check.Name): $($check.Detail)" -ForegroundColor $color
            }
            # Save report JSON
            $reportFile = Join-Path $PackagePath "healthcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $healthResult | ConvertTo-Json -Depth 5 | Set-Content $reportFile -Encoding UTF8
            Write-Host ""
            Write-Host "  Report saved: $reportFile" -ForegroundColor Cyan
        }

        # =============================================
        # CLI: ROLLBACK - Reverse a migration import
        # =============================================
        'rollback' {
            if (-not $PackagePath) {
                Write-Host "ERROR: -PackagePath is required for rollback." -ForegroundColor Red
                exit 1
            }
            $snapshotPath = Join-Path $PackagePath "RollbackSnapshot"
            if (-not (Test-Path $snapshotPath)) {
                Write-Host "ERROR: No rollback snapshot found at $snapshotPath" -ForegroundColor Red
                Write-Host "Rollback snapshots are created automatically during import." -ForegroundColor Yellow
                exit 1
            }
            Write-Host ""
            Write-Host "  WARNING: This will attempt to reverse the migration import." -ForegroundColor Yellow
            Write-Host "  Registry keys will be restored and files added by import will be removed." -ForegroundColor Yellow
            Write-Host ""

            Write-MigrationLog -Message "CLI rollback from $snapshotPath" -Level Info
            try {
                $rollbackResult = Invoke-RollbackRestore -SnapshotPath $snapshotPath
                if ($rollbackResult.Success) {
                    Write-Host "  Rollback complete:" -ForegroundColor Green
                    Write-Host "    Registry keys restored: $($rollbackResult.RegistryKeysRestored)" -ForegroundColor White
                    Write-Host "    Files removed: $($rollbackResult.FilesRemoved)" -ForegroundColor White
                    if ($rollbackResult.Warnings.Count -gt 0) {
                        foreach ($w in $rollbackResult.Warnings) {
                            Write-Host "    WARNING: $w" -ForegroundColor Yellow
                        }
                    }
                } else {
                    Write-Host "  Rollback failed. Check log for details." -ForegroundColor Red
                }
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        }

        default {
            Write-Host "ERROR: Unknown CLI action '$CLI'" -ForegroundColor Red
            Write-Host ""
            Write-Host "Available CLI actions:" -ForegroundColor Yellow
            Write-Host "  scan        - Scan this PC and report all discoverable items" -ForegroundColor White
            Write-Host "  export      - Export a full migration package" -ForegroundColor White
            Write-Host "  import      - Import/restore from a migration package" -ForegroundColor White
            Write-Host "  validate    - Validate a migration package integrity" -ForegroundColor White
            Write-Host "  status      - Show migration status from registry" -ForegroundColor White
            Write-Host "  diff        - Compare two migration packages" -ForegroundColor White
            Write-Host "  healthcheck - Run post-migration health verification" -ForegroundColor White
            Write-Host "  rollback    - Reverse a migration import" -ForegroundColor White
            Write-Host ""
            Write-Host "Examples:" -ForegroundColor Yellow
            Write-Host "  .\Win11Migrator.ps1 -CLI scan" -ForegroundColor DarkGray
            Write-Host "  .\Win11Migrator.ps1 -CLI export -PackagePath 'D:\Migration'" -ForegroundColor DarkGray
            Write-Host "  .\Win11Migrator.ps1 -CLI import -PackagePath 'D:\Migration\Win11Migration_PC1'" -ForegroundColor DarkGray
            Write-Host "  .\Win11Migrator.ps1 -CLI validate -PackagePath 'D:\Migration\Win11Migration_PC1'" -ForegroundColor DarkGray
            Write-Host "  .\Win11Migrator.ps1 -CLI diff -PackagePath 'pkg1' -ComparePath 'pkg2'" -ForegroundColor DarkGray
            Write-Host "  .\Win11Migrator.ps1 -CLI healthcheck -PackagePath 'D:\Migration\Win11Migration_PC1'" -ForegroundColor DarkGray
            Write-Host "  .\Win11Migrator.ps1 -CLI rollback -PackagePath 'D:\Migration\Win11Migration_PC1'" -ForegroundColor DarkGray
            exit 1
        }
    }
} else {
    # Load and launch WPF GUI
    try {
        Add-Type -AssemblyName PresentationFramework
        Invoke-Win11MigratorSelfUpdate -CurrentVersion ([version]$script:MigratorVersion) -Automatic
    } catch {
        Write-MigrationLog -Message "Update check failed: $($_.Exception.Message)" -Level Warning
    }
    . "$script:MigratorRoot\GUI\MainWindow.ps1"
    Show-MainWindow -Config $script:Config -MigratorRoot $script:MigratorRoot
}

Write-MigrationLog -Message "Win11Migrator exiting" -Level Info
