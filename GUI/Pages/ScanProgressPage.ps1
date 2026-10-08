<#
========================================================================================================
    Title:          Win11Migrator - Scan Progress Page
    Filename:       ScanProgressPage.ps1
    Description:    Displays real-time progress during the source PC application and data scanning phase.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ScanProgressPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store all controls in a single hashtable so closures can access them
    $ui = @{
        Title          = $Page.FindName('txtTitle')
        Status         = $Page.FindName('txtScanStatus')
        Progress       = $Page.FindName('progressOverall')
        Percent        = $Page.FindName('txtProgressPercent')
        BtnStart       = $Page.FindName('btnStartScan')
        IconApps       = $Page.FindName('iconApps')
        IconData       = $Page.FindName('iconUserData')
        IconBrowser    = $Page.FindName('iconBrowsers')
        IconSettings   = $Page.FindName('iconSettings')
        IconInstall    = $Page.FindName('iconInstallMethods')
        CountApps      = $Page.FindName('txtAppsCount')
        CountData      = $Page.FindName('txtUserDataSize')
        CountBrowser   = $Page.FindName('txtBrowserCount')
        CountSettings  = $Page.FindName('txtSettingsCount')
        CountInstall   = $Page.FindName('txtInstallMethodCount')
        IconAppProfiles = $Page.FindName('iconAppProfiles')
        CountAppProfiles = $Page.FindName('txtAppProfileCount')
        Log            = $Page.FindName('txtLog')
    }

    # Debug: verify controls loaded
    foreach ($key in $ui.Keys) {
        if (-not $ui[$key]) { Write-Host "[WARN] UI control '$key' is null" -ForegroundColor Yellow }
    }

    $State.BtnNext.IsEnabled = $false
    $scanCtx = @{
        Phase         = -1
        AppJob        = $null
        ResolveJob    = $null
        ResolveShared = $null
        ChocoJob      = $null
        ChocoShared   = $null
        LocalJob      = $null
        LocalShared   = $null
    }
    # Register scan context so MainWindow cleanup can stop active scan jobs on window close
    $State['ScanCtx'] = $scanCtx

    # Start Scan button
    $ui.BtnStart.Add_Click({
        Write-Host "[SCAN] Start Scan clicked" -ForegroundColor Cyan
        $ui.BtnStart.Visibility = 'Collapsed'
        $ui.Progress.Visibility = 'Visible'
        $ui.Percent.Visibility = 'Visible'
        $ui.Title.Text = "Scanning your PC..."
        $ui.Status.Text = "Discovering installed applications..."
        $scanCtx.Phase = 0
    }.GetNewClosure())

    # Timer-driven scan
    $State.OnTick = {
        param($s)

        switch ($scanCtx.Phase) {
            # ---- Phase 0: Launch background registry scan ----
            0 {
                Write-Host "[SCAN] Phase 0: Launching background registry scan" -ForegroundColor Cyan
                $ui.IconApps.Text = [char]0x25BA
                $ui.IconApps.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                $ui.CountApps.Text = "Scanning..."
                if ($ui.Log) { $ui.Log.AppendText("[Phase 1/6] Scanning installed applications...`r`n") }
                $ui.Progress.Value = 5
                $ui.Percent.Text = "5%"

                try {
                    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                    $runspace.Open()
                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.Runspace = $runspace
                    $ps.AddScript({
                        $regPaths = @(
                            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                        )
                        $seen = @{}
                        $apps = [System.Collections.ArrayList]::new()
                        foreach ($path in $regPaths) {
                            $entries = Get-ItemProperty $path -ErrorAction SilentlyContinue
                            foreach ($entry in $entries) {
                                if ($entry.DisplayName -and $entry.DisplayName.Trim() -ne '') {
                                    $key = $entry.DisplayName.ToLower().Trim()
                                    if (-not $seen[$key]) {
                                        $seen[$key] = $true
                                        $apps.Add(@{
                                            Name = $entry.DisplayName
                                            Version = $entry.DisplayVersion
                                            Publisher = $entry.Publisher
                                            InstallLocation = $entry.InstallLocation
                                        }) | Out-Null
                                    }
                                }
                            }
                        }
                        return , $apps
                    }) | Out-Null
                    $handle = $ps.BeginInvoke()
                    $scanCtx.AppJob = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
                    Write-Host "[SCAN] Background job started" -ForegroundColor Cyan
                } catch {
                    Write-Host "[SCAN] Failed to start background job: $($_.Exception.Message)" -ForegroundColor Red
                    $ui.CountApps.Text = "Error"
                    $s.Apps = @()
                }
                $scanCtx.Phase = 1
            }

            # ---- Phase 1: Poll for registry scan completion ----
            1 {
                $job = $scanCtx.AppJob
                if ($job -and $job.Handle.IsCompleted) {
                    Write-Host "[SCAN] Phase 1: Background job completed" -ForegroundColor Cyan
                    # Defensive dot-source: ensure functions are available in closure scope
                    $migratorRoot = $s.MigratorRoot
                    . (Join-Path $migratorRoot "Core\Write-MigrationLog.ps1")
                    . (Join-Path $migratorRoot "Modules\AppDiscovery\Get-NormalizedAppName.ps1")
                    try {
                        $result = $job.PowerShell.EndInvoke($job.Handle)
                        $appList = @($result)
                        if ($appList.Count -eq 1 -and $appList[0] -is [System.Collections.ArrayList]) {
                            $appList = @($appList[0])
                        }

                        # Load exclusion patterns and hardware publishers for filtering
                        $excludedPatterns = @()
                        $excludedPath = Join-Path $s.MigratorRoot "Config\ExcludedApps.json"
                        if (Test-Path $excludedPath) {
                            try { $excludedPatterns = Get-Content $excludedPath -Raw | ConvertFrom-Json } catch {}
                        }
                        $hardwarePublishers = @(
                            'NVIDIA Corporation', 'Advanced Micro Devices*', 'Intel Corporation', 'Intel(R) Corporation',
                            'Realtek Semiconductor*', 'Realtek', 'Qualcomm*', 'Broadcom*', 'Synaptics*',
                            'ELAN Microelectronics*', 'Alps Electric*', 'Conexant*', 'IDT*', 'Marvell*', 'MediaTek*', 'Tobii*'
                        )

                        # Convert hashtables from runspace into MigrationApp objects, applying exclusion filters
                        $migApps = [System.Collections.ArrayList]::new()
                        $excludedCount = 0
                        $totalRaw = $appList.Count
                        foreach ($app in $appList) {
                            $name = $app.Name
                            $publisher = if ($app.Publisher) { $app.Publisher } else { '' }

                            # Check exclusion patterns
                            $excluded = $false
                            foreach ($pattern in $excludedPatterns) {
                                if ($name -like $pattern) { $excluded = $true; break }
                            }
                            if (-not $excluded) {
                                foreach ($hwPub in $hardwarePublishers) {
                                    if ($publisher -like $hwPub) { $excluded = $true; break }
                                }
                            }
                            if ($excluded) { $excludedCount++; continue }

                            $migApp = [MigrationApp]::new()
                            $migApp.Name = $name
                            $migApp.NormalizedName = Get-NormalizedAppName -Name $name
                            $migApp.Version = $app.Version
                            $migApp.Publisher = $publisher
                            $migApp.InstallLocation = $app.InstallLocation
                            $migApp.Source = 'Registry'
                            $migApp.Selected = $true
                            $migApps.Add($migApp) | Out-Null
                        }
                        $s.Apps = $migApps
                        $s['ExcludedDriverCount'] = $excludedCount
                        $s['TotalRawAppCount'] = $totalRaw
                        $ui.CountApps.Text = "$($migApps.Count) found"
                        $ui.IconApps.Text = [char]0x25CF
                        $ui.IconApps.Foreground = [System.Windows.Media.Brushes]::Green
                        if ($ui.Log) {
                            $ui.Log.AppendText("  Found $totalRaw total, excluded $excludedCount drivers/hardware`r`n")
                            $ui.Log.AppendText("  $($migApps.Count) applications for migration`r`n")
                        }
                        Write-Host "[SCAN] Found $($migApps.Count) apps ($excludedCount drivers/hardware excluded)" -ForegroundColor Green
                    } catch {
                        Write-Host "[SCAN] EndInvoke error: $($_.Exception.Message)" -ForegroundColor Red
                        if ($ui.Log) { $ui.Log.AppendText("  [ERROR] $($_.Exception.Message)`r`n") }
                        $ui.CountApps.Text = "Error"
                        $s.Apps = @()
                    } finally {
                        try {
                            $job.PowerShell.Dispose()
                            $job.Runspace.Close()
                            $job.Runspace.Dispose()
                        } catch {}
                        $scanCtx.AppJob = $null
                    }
                    $ui.Progress.Value = 20
                    $ui.Percent.Text = "20%"
                    $scanCtx.Phase = 2
                } elseif (-not $job) {
                    # Job failed to start, skip
                    $scanCtx.Phase = 2
                } else {
                    $dots = '.' * ((Get-Date).Second % 4 + 1)
                    $ui.Status.Text = "Discovering installed applications$dots"
                }
            }

            # ---- Phase 2: User Data (start) + OS Detection ----
            2 {
                Write-Host "[SCAN] Phase 2: User data" -ForegroundColor Cyan
                $ui.IconData.Text = [char]0x25BA
                $ui.IconData.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                $ui.Status.Text = "Checking user data folders..."
                $ui.CountData.Text = "Scanning..."
                if ($ui.Log) { $ui.Log.AppendText("[Phase 2/6] Checking user data folders...`r`n") }

                # Detect OS version for cross-OS migration support
                try {
                    $migratorRoot = $s.MigratorRoot
                    $script:MigratorRoot = $migratorRoot
                    . (Join-Path $migratorRoot "Core\Write-MigrationLog.ps1")
                    $osCtxPath = Join-Path $migratorRoot "Core\Get-OSMigrationContext.ps1"
                    if (Test-Path $osCtxPath) {
                        . $osCtxPath
                        $osCtx = Get-OSMigrationContext
                        $s['OSContext'] = $osCtx
                        $osLabel = if ($osCtx.IsWindows11) { "Windows 11 (Build $($osCtx.BuildNumber))" } elseif ($osCtx.IsWindows10) { "Windows 10 (Build $($osCtx.BuildNumber))" } else { "Windows (Build $($osCtx.BuildNumber))" }
                        if ($ui.Log) { $ui.Log.AppendText("  Detected OS: $osLabel`r`n") }
                        Write-Host "[SCAN] OS detected: $osLabel" -ForegroundColor Green
                    }
                } catch {
                    Write-Host "[SCAN] OS detection error: $($_.Exception.Message)" -ForegroundColor Yellow
                }

                $ui.Progress.Value = 22
                $ui.Percent.Text = "22%"
                $scanCtx.Phase = 3
            }

            # ---- Phase 3: User Data (execute via Get-UserProfilePaths) ----
            3 {
                try {
                    $userData = @()

                    # Dot-source the profile path resolver and its log dependency
                    $migratorRoot = $s.MigratorRoot
                    $script:MigratorRoot = $migratorRoot
                    . (Join-Path $migratorRoot "Modules\UserData\Get-UserProfilePaths.ps1")
                    . (Join-Path $migratorRoot "Core\Write-MigrationLog.ps1")

                    # Get registry-resolved paths (accounts for OneDrive Known Folder Move)
                    $profilePaths = Get-UserProfilePaths
                    $defaultFolders = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'Favorites')

                    # Detect Google Drive sync folder for cloud detection
                    . (Join-Path $migratorRoot "Modules\StorageTargets\Find-CloudSyncFolders.ps1")
                    $cloudFolders = Find-CloudSyncFolders

                    foreach ($folder in $defaultFolders) {
                        $folderPath = $profilePaths[$folder]
                        if (-not $folderPath) { $folderPath = Join-Path $env:USERPROFILE $folder }
                        if (Test-Path $folderPath) {
                            $topItems = @(Get-ChildItem $folderPath -ErrorAction SilentlyContinue -Force)
                            $isOneDrive = ($folderPath -match 'OneDrive')
                            $isGoogleDrive = $false
                            if ($cloudFolders.GoogleDriveAvailable -and $cloudFolders.GoogleDrivePath) {
                                $gdNorm = $cloudFolders.GoogleDrivePath.TrimEnd('\')
                                $isGoogleDrive = ($folderPath -like "$gdNorm\*" -or $folderPath -eq $gdNorm)
                            }
                            $isCloudSynced = ($isOneDrive -or $isGoogleDrive)
                            $cloudProvider = if ($isOneDrive) { 'OneDrive' } elseif ($isGoogleDrive) { 'GoogleDrive' } else { '' }
                            $userData += @{ Name = $folder; SourcePath = $folderPath; ItemCount = $topItems.Count; Selected = $true; IsOneDrive = $isOneDrive; IsCloudSynced = $isCloudSynced; CloudProvider = $cloudProvider; SkipCloudSync = $false }
                            $label = if ($isOneDrive) { "$folder (OneDrive) - $($topItems.Count) items" } elseif ($isGoogleDrive) { "$folder (Google Drive) - $($topItems.Count) items" } else { "$folder - $($topItems.Count) items" }
                            if ($ui.Log) { $ui.Log.AppendText("  $label`r`n") }
                        }
                    }
                    $s.UserData = $userData
                    $ui.CountData.Text = "$($userData.Count) folders"
                    $ui.IconData.Text = [char]0x25CF
                    $ui.IconData.Foreground = [System.Windows.Media.Brushes]::Green
                    Write-Host "[SCAN] User data: $($userData.Count) folders" -ForegroundColor Green
                } catch {
                    Write-Host "[SCAN] User data error: $($_.Exception.Message)" -ForegroundColor Red
                    $ui.CountData.Text = "Error"
                    $s.UserData = @()
                }
                # Run EFS encryption detection on user data folders
                try {
                    $migratorRoot = $s.MigratorRoot
                    $efsPath = Join-Path $migratorRoot "Modules\UserData\Test-EFSEncryption.ps1"
                    if (Test-Path $efsPath) {
                        . $efsPath
                        $efsResults = @()
                        foreach ($ud in $userData) {
                            $efsResult = Test-EFSEncryption -Path $ud.SourcePath
                            if ($efsResult -and $efsResult.EncryptedFiles.Count -gt 0) {
                                $efsResults += $efsResult
                            }
                        }
                        if ($efsResults.Count -gt 0) {
                            $totalEFS = ($efsResults | Measure-Object -Property { $_.EncryptedFiles.Count } -Sum).Sum
                            $s['EFSWarning'] = $true
                            $s['EFSResults'] = $efsResults
                            if ($ui.Log) { $ui.Log.AppendText("  WARNING: $totalEFS EFS-encrypted file(s) detected!`r`n") }
                            Write-Host "[SCAN] EFS WARNING: $totalEFS encrypted files found" -ForegroundColor Yellow
                        }
                    }
                } catch {
                    Write-Host "[SCAN] EFS check error: $($_.Exception.Message)" -ForegroundColor Yellow
                }

                $ui.Progress.Value = 35
                $ui.Percent.Text = "35%"
                $scanCtx.Phase = 4
            }

            # ---- Phase 4: Browser Profiles (start) ----
            4 {
                Write-Host "[SCAN] Phase 4: Browsers" -ForegroundColor Cyan
                $ui.IconBrowser.Text = [char]0x25BA
                $ui.IconBrowser.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                $ui.Status.Text = "Detecting browser profiles..."
                $ui.CountBrowser.Text = "Scanning..."
                if ($ui.Log) { $ui.Log.AppendText("[Phase 3/6] Detecting browser profiles...`r`n") }
                $ui.Progress.Value = 37
                $ui.Percent.Text = "37%"
                $scanCtx.Phase = 5
            }

            # ---- Phase 5: Browser Profiles (execute) ----
            5 {
                try {
                    $browsers = @()
                    $localAppData = $env:LOCALAPPDATA
                    $appData = $env:APPDATA
                    $browserDefs = @(
                        @{ Name = 'Chrome'; Path = Join-Path $localAppData "Google\Chrome\User Data"; Filter = $true }
                        @{ Name = 'Edge';   Path = Join-Path $localAppData "Microsoft\Edge\User Data"; Filter = $true }
                        @{ Name = 'Brave';  Path = Join-Path $localAppData "BraveSoftware\Brave-Browser\User Data"; Filter = $true }
                        @{ Name = 'Firefox'; Path = Join-Path $appData "Mozilla\Firefox\Profiles"; Filter = $false }
                    )
                    foreach ($def in $browserDefs) {
                        if (Test-Path $def.Path) {
                            if ($def.Filter) {
                                $profiles = @(Get-ChildItem $def.Path -Directory -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' })
                            } else {
                                $profiles = @(Get-ChildItem $def.Path -Directory -ErrorAction SilentlyContinue)
                            }
                            foreach ($p in $profiles) {
                                $browsers += @{ Browser = $def.Name; ProfileName = $p.Name; ProfilePath = $p.FullName; Selected = $true; ExportStatus = 'Pending' }
                            }
                            if ($ui.Log) { $ui.Log.AppendText("  $($def.Name): $($profiles.Count) profile(s)`r`n") }
                        }
                    }
                    $s.BrowserProfiles = $browsers
                    $ui.CountBrowser.Text = "$($browsers.Count) profile(s)"
                    $ui.IconBrowser.Text = [char]0x25CF
                    $ui.IconBrowser.Foreground = [System.Windows.Media.Brushes]::Green
                    Write-Host "[SCAN] Browsers: $($browsers.Count) profiles" -ForegroundColor Green
                } catch {
                    Write-Host "[SCAN] Browser error: $($_.Exception.Message)" -ForegroundColor Red
                    $ui.CountBrowser.Text = "Error"
                    $s.BrowserProfiles = @()
                }
                $ui.Progress.Value = 50
                $ui.Percent.Text = "50%"
                $scanCtx.Phase = 6
            }

            # ---- Phase 6: System Settings (start) ----
            6 {
                Write-Host "[SCAN] Phase 6: Settings" -ForegroundColor Cyan
                $ui.IconSettings.Text = [char]0x25BA
                $ui.IconSettings.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                $ui.Status.Text = "Collecting system settings..."
                $ui.CountSettings.Text = "Scanning..."
                if ($ui.Log) { $ui.Log.AppendText("[Phase 4/6] Collecting system settings...`r`n") }
                $ui.Progress.Value = 52
                $ui.Percent.Text = "52%"
                $scanCtx.Phase = 7
            }

            # ---- Phase 7: System Settings (execute) ----
            7 {
                try {
                    $settings = @()
                    try {
                        $wifiOutput = netsh wlan show profiles 2>$null
                        $wifiProfiles = @($wifiOutput | Select-String 'All User Profile\s*:\s*(.+)' |
                            ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
                        if ($wifiProfiles.Count -gt 0) {
                            $settings += @{ Category = 'WiFi'; Count = $wifiProfiles.Count }
                            if ($ui.Log) { $ui.Log.AppendText("  WiFi profiles: $($wifiProfiles.Count)`r`n") }
                        }
                    } catch {}

                    try {
                        $printers = @(Get-Printer -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -notmatch 'Microsoft|OneNote|Fax' })
                        if ($printers.Count -gt 0) {
                            $settings += @{ Category = 'Printers'; Count = $printers.Count }
                            if ($ui.Log) { $ui.Log.AppendText("  Printers: $($printers.Count)`r`n") }
                        }
                    } catch {}

                    try {
                        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                            Where-Object { $_.DisplayRoot -and $_.DisplayRoot.StartsWith('\\') })
                        if ($drives.Count -gt 0) {
                            $settings += @{ Category = 'MappedDrives'; Count = $drives.Count }
                            if ($ui.Log) { $ui.Log.AppendText("  Mapped drives: $($drives.Count)`r`n") }
                        }
                    } catch {}

                    try {
                        $userEnv = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::User)
                        $settings += @{ Category = 'EnvVars'; Count = $userEnv.Count }
                        if ($ui.Log) { $ui.Log.AppendText("  User env vars: $($userEnv.Count)`r`n") }
                    } catch {}

                    $s.SystemSettings = $settings
                    $totalItems = ($settings | Measure-Object -Property Count -Sum).Sum
                    $ui.CountSettings.Text = "$totalItems items"
                    $ui.IconSettings.Text = [char]0x25CF
                    $ui.IconSettings.Foreground = [System.Windows.Media.Brushes]::Green
                    Write-Host "[SCAN] Settings: $totalItems items" -ForegroundColor Green
                } catch {
                    Write-Host "[SCAN] Settings error: $($_.Exception.Message)" -ForegroundColor Red
                    $ui.CountSettings.Text = "Error"
                    $s.SystemSettings = @()
                }

                $ui.Progress.Value = 55
                $ui.Percent.Text = "55%"
                $scanCtx.Phase = 75
            }

            # ---- Phase 75: Application Profile detection ----
            75 {
                Write-Host "[SCAN] Phase 75: Application profiles" -ForegroundColor Cyan
                $ui.IconAppProfiles.Text = [char]0x25BA
                $ui.IconAppProfiles.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                $ui.CountAppProfiles.Text = "Scanning..."
                $ui.Status.Text = "Detecting application profiles..."
                if ($ui.Log) { $ui.Log.AppendText("[Phase 5/6] Detecting application profiles...`r`n") }

                try {
                    $migratorRoot = $s.MigratorRoot
                    $script:MigratorRoot = $migratorRoot
                    . (Join-Path $migratorRoot "Modules\AppProfiles\Export-AppProfiles.ps1")
                    . (Join-Path $migratorRoot "Core\Write-MigrationLog.ps1")

                    $profiles = @(Get-DetectedAppProfiles -InstalledApps $s.Apps)
                    $s.AppProfiles = $profiles

                    $ui.CountAppProfiles.Text = "$($profiles.Count) detected"
                    $ui.IconAppProfiles.Text = [char]0x25CF
                    $ui.IconAppProfiles.Foreground = [System.Windows.Media.Brushes]::Green
                    if ($ui.Log) {
                        foreach ($p in $profiles) {
                            $ui.Log.AppendText("  $($p.Name) ($($p.Category)) - $($p.FileCount) files, $($p.RegistryCount) registry`r`n")
                        }
                    }
                    Write-Host "[SCAN] App profiles: $($profiles.Count) detected" -ForegroundColor Green
                } catch {
                    Write-Host "[SCAN] App profiles error: $($_.Exception.Message)" -ForegroundColor Red
                    $ui.CountAppProfiles.Text = "Error"
                    $s.AppProfiles = @()
                }

                $ui.Progress.Value = 60
                $ui.Percent.Text = "60%"
                $scanCtx.Phase = 8
            }

            # ============================================================
            # INSTALL METHOD RESOLUTION (Phases 8-13)
            # ============================================================

            # ---- Phase 8: Launch local catalog resolution in background runspace ----
            8 {
                Write-Host "[SCAN] Phase 8: Launching local catalog resolution" -ForegroundColor Cyan
                $ui.IconInstall.Text = [char]0x25BA
                $ui.IconInstall.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
                $ui.CountInstall.Text = "Resolving..."
                $ui.Status.Text = "Resolving install methods (local catalogs)..."
                if ($ui.Log) { $ui.Log.AppendText("[Phase 6/6] Resolving install methods...`r`n") }

                $migratorRoot = $s.MigratorRoot

                # Build app list as hashtables for runspace transfer
                $appData = [System.Collections.ArrayList]::new()
                $apps = $s.Apps
                if ($apps -and $apps.Count -gt 0) {
                    for ($i = 0; $i -lt $apps.Count; $i++) {
                        $appData.Add(@{
                            Index     = $i
                            Name      = $apps[$i].Name
                            NormName  = $apps[$i].NormalizedName
                        }) | Out-Null
                    }
                }

                $localShared = [hashtable]::Synchronized(@{
                    Results = [System.Collections.ArrayList]::new()
                    Done    = $false
                    Current = 0
                    Total   = $appData.Count
                })
                $scanCtx.LocalShared = $localShared

                try {
                    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                    $runspace.Open()
                    $runspace.SessionStateProxy.SetVariable('migratorRoot', $migratorRoot)
                    $runspace.SessionStateProxy.SetVariable('appData', $appData)
                    $runspace.SessionStateProxy.SetVariable('shared', $localShared)

                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.Runspace = $runspace
                    $ps.AddScript({
                        . (Join-Path $migratorRoot "Modules\AppDiscovery\Get-NormalizedAppName.ps1")
                        . (Join-Path $migratorRoot "Modules\AppDiscovery\Search-NinitePackage.ps1")
                        . (Join-Path $migratorRoot "Modules\AppDiscovery\Search-StorePackage.ps1")
                        . (Join-Path $migratorRoot "Modules\AppDiscovery\Search-VendorDownload.ps1")
                        function Write-MigrationLog { param([string]$Message, [string]$Level = 'Info') Write-Host "[$Level] $Message" }
                        $script:MigratorRoot = $migratorRoot

                        # Load WingetIdMap for static lookup (highest priority)
                        $wingetIdMap = @{}
                        $mapPath = Join-Path $migratorRoot "Config\WingetIdMap.json"
                        if (Test-Path $mapPath) {
                            try {
                                $mapRaw = Get-Content $mapPath -Raw | ConvertFrom-Json
                                $mapRaw.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
                                    $wingetIdMap[$_.Name] = $_.Value
                                }
                            } catch {}
                        }

                        foreach ($item in $appData) {
                            $shared.Current++
                            $name = $item.Name
                            $normName = $item.NormName
                            if ([string]::IsNullOrWhiteSpace($normName)) {
                                $normName = Get-NormalizedAppName -Name $name
                            }

                            # Try WingetIdMap (static, highest priority)
                            if ($wingetIdMap.Count -gt 0) {
                                # Exact match
                                $lookupKeys = @($normName, $name.ToLower().Trim()) | Select-Object -Unique
                                $wingetMatch = $null
                                foreach ($key in $lookupKeys) {
                                    if ($wingetIdMap.ContainsKey($key)) {
                                        $wingetMatch = @{ PackageId = $wingetIdMap[$key]; Confidence = 0.95 }
                                        break
                                    }
                                }
                                # Fuzzy match if no exact hit
                                if (-not $wingetMatch) {
                                    $bestKey = ''; $bestSim = 0.0
                                    foreach ($key in $wingetIdMap.Keys) {
                                        $sim = Get-AppNameSimilarity -Name1 $normName -Name2 $key
                                        if ($sim -gt $bestSim) { $bestSim = $sim; $bestKey = $key }
                                    }
                                    if ($bestSim -ge 0.6 -and $bestKey) {
                                        $wingetMatch = @{ PackageId = $wingetIdMap[$bestKey]; Confidence = $bestSim }
                                    }
                                }
                                if ($wingetMatch) {
                                    $null = $shared.Results.Add(@{ Index = $item.Index; Method = 'Winget'; PackageId = $wingetMatch.PackageId; Confidence = $wingetMatch.Confidence; NormName = $normName })
                                    continue
                                }
                            }

                            # Try Ninite
                            try {
                                $r = Search-NinitePackage -AppName $name -NormalizedName $normName
                                if ($r.Found) {
                                    $null = $shared.Results.Add(@{ Index = $item.Index; Method = 'Ninite'; PackageId = $r.PackageId; Confidence = $r.Confidence; NormName = $normName })
                                    continue
                                }
                            } catch {}

                            # Try Store
                            try {
                                $r = Search-StorePackage -AppName $name -NormalizedName $normName
                                if ($r.Found) {
                                    $null = $shared.Results.Add(@{ Index = $item.Index; Method = 'Store'; PackageId = $r.PackageId; Confidence = $r.Confidence; NormName = $normName })
                                    continue
                                }
                            } catch {}

                            # Try VendorDownload
                            try {
                                $r = Search-VendorDownload -AppName $name -NormalizedName $normName
                                if ($r.Found) {
                                    $null = $shared.Results.Add(@{ Index = $item.Index; Method = 'VendorDownload'; DownloadUrl = $r.DownloadUrl; Confidence = $r.Confidence; NormName = $normName })
                                    continue
                                }
                            } catch {}
                        }
                        $shared.Done = $true
                    }) | Out-Null

                    $handle = $ps.BeginInvoke()
                    $scanCtx.LocalJob = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
                    Write-Host "[SCAN] Local catalog job started" -ForegroundColor Cyan
                } catch {
                    Write-Host "[SCAN] Failed to start local catalog job: $($_.Exception.Message)" -ForegroundColor Red
                    if ($ui.Log) { $ui.Log.AppendText("  [ERROR] Local catalog job failed to start`r`n") }
                    $ui.Progress.Value = 65
                    $ui.Percent.Text = "65%"
                    $scanCtx.Phase = 9
                    break
                }

                $scanCtx.Phase = 85
            }

            # ---- Phase 85: Poll local catalog completion ----
            85 {
                $job = $scanCtx.LocalJob
                $localShared = $scanCtx.LocalShared

                if ($job -and $job.Handle.IsCompleted) {
                    Write-Host "[SCAN] Phase 85: Local catalog resolution completed" -ForegroundColor Cyan
                    try {
                        $job.PowerShell.EndInvoke($job.Handle)
                    } catch {
                        Write-Host "[SCAN] Local catalog EndInvoke error: $($_.Exception.Message)" -ForegroundColor Red
                    }

                    # Map results back to MigrationApp objects
                    $localCount = 0
                    $apps = $s.Apps
                    foreach ($result in $localShared.Results) {
                        $idx = $result.Index
                        if ($idx -ge 0 -and $idx -lt $apps.Count -and [string]::IsNullOrWhiteSpace($apps[$idx].InstallMethod)) {
                            $apps[$idx].InstallMethod = $result.Method
                            if ($result.PackageId) { $apps[$idx].PackageId = $result.PackageId }
                            if ($result.DownloadUrl) { $apps[$idx].DownloadUrl = $result.DownloadUrl }
                            $apps[$idx].MatchConfidence = $result.Confidence
                            if ($result.NormName -and [string]::IsNullOrWhiteSpace($apps[$idx].NormalizedName)) {
                                $apps[$idx].NormalizedName = $result.NormName
                            }
                            $localCount++
                        }
                    }

                    if ($ui.Log) { $ui.Log.AppendText("  Local catalogs: $localCount resolved`r`n") }
                    Write-Host "[SCAN] Local catalogs resolved: $localCount" -ForegroundColor Green

                    try {
                        $job.PowerShell.Dispose()
                        $job.Runspace.Close()
                        $job.Runspace.Dispose()
                    } catch {}
                    $scanCtx.LocalJob = $null
                    $scanCtx.LocalShared = $null

                    $ui.Progress.Value = 65
                    $ui.Percent.Text = "65%"
                    $scanCtx.Phase = 9
                } elseif (-not $job) {
                    $scanCtx.Phase = 9
                } else {
                    # Update progress
                    if ($localShared) {
                        $dots = '.' * ((Get-Date).Second % 4 + 1)
                        $ui.Status.Text = "Resolving local catalogs$dots ($($localShared.Current)/$($localShared.Total))"
                        $pct = 60 + [Math]::Floor(($localShared.Current / [Math]::Max($localShared.Total, 1)) * 5)
                        $ui.Progress.Value = [Math]::Min($pct, 64)
                        $ui.Percent.Text = "$([Math]::Min($pct, 64))%"
                    }
                }
            }

            # ---- Phase 9: Launch winget background runspace ----
            9 {
                $apps = $s.Apps
                # Build list of unresolved apps (as hashtables for runspace transfer)
                $unresolvedApps = [System.Collections.ArrayList]::new()
                if ($apps -and $apps.Count -gt 0) {
                    for ($i = 0; $i -lt $apps.Count; $i++) {
                        if ([string]::IsNullOrWhiteSpace($apps[$i].InstallMethod)) {
                            $unresolvedApps.Add(@{
                                Index          = $i
                                Name           = $apps[$i].Name
                                NormalizedName = $apps[$i].NormalizedName
                            }) | Out-Null
                        }
                    }
                }

                # Check if winget is available
                $hasWinget = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

                if ($unresolvedApps.Count -eq 0 -or -not $hasWinget) {
                    if (-not $hasWinget) {
                        if ($ui.Log) { $ui.Log.AppendText("  Winget not available, skipping`r`n") }
                        Write-Host "[SCAN] Winget not found, skipping" -ForegroundColor Yellow
                    } else {
                        if ($ui.Log) { $ui.Log.AppendText("  All apps already resolved, skipping winget`r`n") }
                    }
                    $ui.Progress.Value = 95
                    $ui.Percent.Text = "95%"
                    $scanCtx.Phase = 13  # Skip to finalize
                    break
                }

                Write-Host "[SCAN] Phase 9: Launching winget resolution for $($unresolvedApps.Count) apps" -ForegroundColor Cyan
                $ui.Status.Text = "Resolving via winget (0/$($unresolvedApps.Count))..."

                $migratorRoot = $s.MigratorRoot
                $shared = [hashtable]::Synchronized(@{
                    Current    = 0
                    Total      = $unresolvedApps.Count
                    CurrentApp = ''
                    Results    = [System.Collections.ArrayList]::new()
                    Done       = $false
                })
                $scanCtx.ResolveShared = $shared

                try {
                    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                    $runspace.Open()
                    $runspace.SessionStateProxy.SetVariable('migratorRoot', $migratorRoot)
                    $runspace.SessionStateProxy.SetVariable('unresolvedApps', $unresolvedApps)
                    $runspace.SessionStateProxy.SetVariable('shared', $shared)

                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.Runspace = $runspace
                    $ps.AddScript({
                        foreach ($core in 'Initialize-Environment', 'Write-MigrationLog') { . (Join-Path $migratorRoot "Core\$core.ps1") }
                        foreach ($f in 'Get-NormalizedAppName', 'Get-WingetApps', 'Search-WingetPackage') {
                            . (Join-Path $migratorRoot "Modules\AppDiscovery\$f.ps1")
                        }
                        $script:MigratorRoot = $migratorRoot

                        # Step 1: apps winget already knows are installed, with IDs a source can reinstall
                        $wingetInstalled = @{}
                        try {
                            foreach ($w in @(Get-WingetApps)) {
                                if ($w.PackageId -and $w.NormalizedName) { $wingetInstalled[$w.NormalizedName] = $w.PackageId }
                            }
                        } catch {
                            Write-Host "[WINGET] winget list failed: $($_.Exception.Message)" -ForegroundColor Yellow
                        }

                        $stillUnresolved = [System.Collections.ArrayList]::new()
                        foreach ($appInfo in $unresolvedApps) {
                            $normName = $appInfo.NormalizedName
                            $bestMatch = if ($wingetInstalled.ContainsKey($normName)) { $normName } else { $null }
                            $bestSim = if ($bestMatch) { 1.0 } else { 0.0 }
                            if (-not $bestMatch) {
                                foreach ($wKey in $wingetInstalled.Keys) {
                                    $sim = Get-AppNameSimilarity -Name1 $normName -Name2 $wKey
                                    if ($sim -gt $bestSim) { $bestSim = $sim; $bestMatch = $wKey }
                                }
                            }
                            if ($bestMatch -and $bestSim -ge 0.7) {
                                $null = $shared.Results.Add(@{ Index = $appInfo.Index; Found = $true; PackageId = $wingetInstalled[$bestMatch]; Confidence = $bestSim })
                            } else {
                                $null = $stillUnresolved.Add($appInfo)
                            }
                        }

                        # Step 2: search for the rest (cached per product name inside Search-WingetPackage)
                        $shared.Total = $stillUnresolved.Count
                        $shared.Current = 0
                        foreach ($appInfo in $stillUnresolved) {
                            $shared.Current++
                            $shared.CurrentApp = $appInfo.Name
                            try {
                                $found = Search-WingetPackage -AppName $appInfo.Name -NormalizedName $appInfo.NormalizedName
                                if ($found.Found -and $found.Confidence -ge 0.5) {
                                    $null = $shared.Results.Add(@{ Index = $appInfo.Index; Found = $true; PackageId = $found.PackageId; Confidence = $found.Confidence })
                                }
                            } catch {
                                Write-Host "[WINGET] Search failed for '$($appInfo.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
                            }
                        }

                        $shared.Done = $true
                    }) | Out-Null

                    $handle = $ps.BeginInvoke()
                    $scanCtx.ResolveJob = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
                    Write-Host "[SCAN] Winget resolution job started" -ForegroundColor Cyan
                } catch {
                    Write-Host "[SCAN] Failed to start winget job: $($_.Exception.Message)" -ForegroundColor Red
                    if ($ui.Log) { $ui.Log.AppendText("  [ERROR] Winget job failed to start`r`n") }
                    $scanCtx.Phase = 13  # Skip choco, go to finalize
                    break
                }

                $scanCtx.Phase = 10
            }

            # ---- Phase 10: Poll winget completion ----
            10 {
                $job = $scanCtx.ResolveJob
                $shared = $scanCtx.ResolveShared

                if ($job -and $job.Handle.IsCompleted) {
                    Write-Host "[SCAN] Phase 10: Winget resolution completed" -ForegroundColor Cyan
                    try {
                        $job.PowerShell.EndInvoke($job.Handle)
                    } catch {
                        Write-Host "[SCAN] Winget EndInvoke error: $($_.Exception.Message)" -ForegroundColor Red
                    }

                    # Map results back to MigrationApp objects
                    $wingetCount = 0
                    $apps = $s.Apps
                    foreach ($result in $shared.Results) {
                        $idx = $result.Index
                        if ($idx -ge 0 -and $idx -lt $apps.Count -and [string]::IsNullOrWhiteSpace($apps[$idx].InstallMethod)) {
                            $apps[$idx].InstallMethod = 'Winget'
                            $apps[$idx].PackageId = $result.PackageId
                            $apps[$idx].MatchConfidence = $result.Confidence
                            $wingetCount++
                        }
                    }

                    if ($ui.Log) { $ui.Log.AppendText("  Winget: $wingetCount resolved`r`n") }
                    Write-Host "[SCAN] Winget resolved: $wingetCount" -ForegroundColor Green

                    try {
                        $job.PowerShell.Dispose()
                        $job.Runspace.Close()
                        $job.Runspace.Dispose()
                    } catch {}
                    $scanCtx.ResolveJob = $null
                    $scanCtx.ResolveShared = $null

                    $ui.Progress.Value = 95
                    $ui.Percent.Text = "95%"
                    $scanCtx.Phase = 13  # Skip choco, go to finalize
                } elseif (-not $job) {
                    $scanCtx.Phase = 13  # Skip choco, go to finalize
                } else {
                    # Update progress from synchronized hashtable
                    if ($shared) {
                        $current = $shared.Current
                        $total = $shared.Total
                        $appName = $shared.CurrentApp
                        $dots = '.' * ((Get-Date).Second % 4 + 1)
                        if ($total -gt 0) {
                            $ui.Status.Text = "Resolving via winget$dots ($current/$total)"
                            # Scale progress 65-85 based on completion
                            $pct = 65 + [Math]::Floor(($current / [Math]::Max($total, 1)) * 20)
                            $ui.Progress.Value = [Math]::Min($pct, 84)
                            $ui.Percent.Text = "$([Math]::Min($pct, 84))%"
                        } else {
                            $ui.Status.Text = "Resolving via winget$dots"
                        }
                        $ui.CountInstall.Text = "$($shared.Results.Count) matched"
                    }
                }
            }

            # ---- Phase 11: Launch choco background runspace ----
            11 {
                $apps = $s.Apps
                # Build list of still-unresolved apps
                $unresolvedApps = [System.Collections.ArrayList]::new()
                if ($apps -and $apps.Count -gt 0) {
                    for ($i = 0; $i -lt $apps.Count; $i++) {
                        if ([string]::IsNullOrWhiteSpace($apps[$i].InstallMethod)) {
                            $unresolvedApps.Add(@{
                                Index          = $i
                                Name           = $apps[$i].Name
                                NormalizedName = $apps[$i].NormalizedName
                            }) | Out-Null
                        }
                    }
                }

                # Check if choco is available
                $hasChoco = $null -ne (Get-Command choco -ErrorAction SilentlyContinue)

                if ($unresolvedApps.Count -eq 0 -or -not $hasChoco) {
                    if (-not $hasChoco -and $unresolvedApps.Count -gt 0) {
                        if ($ui.Log) { $ui.Log.AppendText("  Chocolatey not available, skipping`r`n") }
                        Write-Host "[SCAN] Chocolatey not found, skipping" -ForegroundColor Yellow
                    } elseif ($unresolvedApps.Count -eq 0) {
                        if ($ui.Log) { $ui.Log.AppendText("  All apps resolved, skipping Chocolatey`r`n") }
                    }
                    $ui.Progress.Value = 95
                    $ui.Percent.Text = "95%"
                    $scanCtx.Phase = 13  # Skip to finalize
                    break
                }

                Write-Host "[SCAN] Phase 11: Launching Chocolatey resolution for $($unresolvedApps.Count) apps" -ForegroundColor Cyan
                $ui.Status.Text = "Resolving via Chocolatey (0/$($unresolvedApps.Count))..."

                $migratorRoot = $s.MigratorRoot
                $chocoShared = [hashtable]::Synchronized(@{
                    Current    = 0
                    Total      = $unresolvedApps.Count
                    CurrentApp = ''
                    Results    = [System.Collections.ArrayList]::new()
                    Done       = $false
                })
                $scanCtx.ChocoShared = $chocoShared

                try {
                    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                    $runspace.Open()
                    $runspace.SessionStateProxy.SetVariable('migratorRoot', $migratorRoot)
                    $runspace.SessionStateProxy.SetVariable('unresolvedApps', $unresolvedApps)
                    $runspace.SessionStateProxy.SetVariable('shared', $chocoShared)

                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.Runspace = $runspace
                    $ps.AddScript({
                        # Dot-source normalization and choco search inside the runspace
                        . (Join-Path $migratorRoot "Modules\AppDiscovery\Get-NormalizedAppName.ps1")
                        . (Join-Path $migratorRoot "Modules\AppDiscovery\Search-ChocolateyPackage.ps1")

                        # Stub Write-MigrationLog
                        function Write-MigrationLog { param([string]$Message, [string]$Level = 'Info') Write-Host "[$Level] $Message" }
                        $script:MigratorRoot = $migratorRoot

                        foreach ($appInfo in $unresolvedApps) {
                            $shared.Current++
                            $shared.CurrentApp = $appInfo.Name

                            try {
                                $result = Search-ChocolateyPackage -AppName $appInfo.Name -NormalizedName $appInfo.NormalizedName
                                if ($result.Found) {
                                    $null = $shared.Results.Add(@{
                                        Index      = $appInfo.Index
                                        Found      = $true
                                        PackageId  = $result.PackageId
                                        Confidence = $result.Confidence
                                    })
                                }
                            } catch {
                                Write-Host "[CHOCO] Search failed for '$($appInfo.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
                            }
                        }

                        $shared.Done = $true
                    }) | Out-Null

                    $handle = $ps.BeginInvoke()
                    $scanCtx.ChocoJob = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
                    Write-Host "[SCAN] Chocolatey resolution job started" -ForegroundColor Cyan
                } catch {
                    Write-Host "[SCAN] Failed to start choco job: $($_.Exception.Message)" -ForegroundColor Red
                    if ($ui.Log) { $ui.Log.AppendText("  [ERROR] Chocolatey job failed to start`r`n") }
                    $scanCtx.Phase = 13
                    break
                }

                $scanCtx.Phase = 12
            }

            # ---- Phase 12: Poll choco completion ----
            12 {
                $job = $scanCtx.ChocoJob
                $chocoShared = $scanCtx.ChocoShared

                if ($job -and $job.Handle.IsCompleted) {
                    Write-Host "[SCAN] Phase 12: Chocolatey resolution completed" -ForegroundColor Cyan
                    try {
                        $job.PowerShell.EndInvoke($job.Handle)
                    } catch {
                        Write-Host "[SCAN] Choco EndInvoke error: $($_.Exception.Message)" -ForegroundColor Red
                    }

                    # Map results back
                    $chocoCount = 0
                    $apps = $s.Apps
                    foreach ($result in $chocoShared.Results) {
                        $idx = $result.Index
                        if ($idx -ge 0 -and $idx -lt $apps.Count -and [string]::IsNullOrWhiteSpace($apps[$idx].InstallMethod)) {
                            $apps[$idx].InstallMethod = 'Chocolatey'
                            $apps[$idx].PackageId = $result.PackageId
                            $apps[$idx].MatchConfidence = $result.Confidence
                            $chocoCount++
                        }
                    }

                    if ($ui.Log) { $ui.Log.AppendText("  Chocolatey: $chocoCount resolved`r`n") }
                    Write-Host "[SCAN] Chocolatey resolved: $chocoCount" -ForegroundColor Green

                    try {
                        $job.PowerShell.Dispose()
                        $job.Runspace.Close()
                        $job.Runspace.Dispose()
                    } catch {}
                    $scanCtx.ChocoJob = $null
                    $scanCtx.ChocoShared = $null

                    $ui.Progress.Value = 95
                    $ui.Percent.Text = "95%"
                    $scanCtx.Phase = 13
                } elseif (-not $job) {
                    $scanCtx.Phase = 13
                } else {
                    # Update progress from synchronized hashtable
                    if ($chocoShared) {
                        $current = $chocoShared.Current
                        $total = $chocoShared.Total
                        $dots = '.' * ((Get-Date).Second % 4 + 1)
                        if ($total -gt 0) {
                            $ui.Status.Text = "Resolving via Chocolatey$dots ($current/$total)"
                            $pct = 85 + [Math]::Floor(($current / [Math]::Max($total, 1)) * 10)
                            $ui.Progress.Value = [Math]::Min($pct, 94)
                            $ui.Percent.Text = "$([Math]::Min($pct, 94))%"
                        } else {
                            $ui.Status.Text = "Resolving via Chocolatey$dots"
                        }
                        $ui.CountInstall.Text = "$($chocoShared.Results.Count) matched"
                    }
                }
            }

            # ---- Phase 13: Finalize ----
            13 {
                Write-Host "[SCAN] Phase 13: Finalizing install methods" -ForegroundColor Cyan
                $apps = $s.Apps

                # Mark all remaining unresolved apps as Manual
                $manualCount = 0
                if ($apps -and $apps.Count -gt 0) {
                    foreach ($app in $apps) {
                        if ([string]::IsNullOrWhiteSpace($app.InstallMethod)) {
                            $app.InstallMethod = 'Manual'
                            $app.MatchConfidence = 0.0
                            $manualCount++
                        }
                    }
                }

                # Build summary by method
                $methodCounts = @{
                    Winget         = 0
                    Chocolatey     = 0
                    Ninite         = 0
                    Store          = 0
                    VendorDownload = 0
                    Manual         = 0
                }
                if ($apps -and $apps.Count -gt 0) {
                    foreach ($app in $apps) {
                        $method = $app.InstallMethod
                        if ($methodCounts.ContainsKey($method)) {
                            $methodCounts[$method]++
                        }
                    }
                }

                $totalApps = if ($apps) { $apps.Count } else { 0 }
                $automated = $totalApps - $methodCounts['Manual']
                $autoPercent = if ($totalApps -gt 0) { [Math]::Round(($automated / $totalApps) * 100, 1) } else { 0 }

                # Build summary string
                $summaryParts = @()
                if ($methodCounts['Winget'] -gt 0)         { $summaryParts += "$($methodCounts['Winget']) Winget" }
                if ($methodCounts['Chocolatey'] -gt 0)     { $summaryParts += "$($methodCounts['Chocolatey']) Choco" }
                if ($methodCounts['Ninite'] -gt 0)         { $summaryParts += "$($methodCounts['Ninite']) Ninite" }
                if ($methodCounts['Store'] -gt 0)          { $summaryParts += "$($methodCounts['Store']) Store" }
                if ($methodCounts['VendorDownload'] -gt 0) { $summaryParts += "$($methodCounts['VendorDownload']) Vendor" }
                if ($methodCounts['Manual'] -gt 0)         { $summaryParts += "$($methodCounts['Manual']) Manual" }
                $summaryText = $summaryParts -join ', '

                $ui.IconInstall.Text = [char]0x25CF
                $ui.IconInstall.Foreground = [System.Windows.Media.Brushes]::Green
                $ui.CountInstall.Text = $summaryText

                if ($ui.Log) {
                    $ui.Log.AppendText("  Summary: $summaryText`r`n")
                    $ui.Log.AppendText("  Automated: $automated/$totalApps ($autoPercent%), Manual: $($methodCounts['Manual'])/$totalApps`r`n")
                    $ui.Log.AppendText("`r`nScan complete! Click Next to continue.`r`n")
                    $ui.Log.ScrollToEnd()
                }
                Write-Host "[SCAN] Install method summary: $summaryText" -ForegroundColor Green
                Write-Host "[SCAN] Automated: $automated/$totalApps ($autoPercent%), Manual: $($methodCounts['Manual'])/$totalApps" -ForegroundColor Green

                $ui.Progress.Value = 100
                $ui.Percent.Text = "100%"
                $ui.Title.Text = "Scan Complete"
                $ui.Status.Text = "Review the results below, then click Next to continue."
                $s.BtnNext.IsEnabled = $true
                $scanCtx.Phase = -1
                $s.ActiveJob = $null
                $s.OnTick = $null
                Write-Host "[SCAN] Scan complete!" -ForegroundColor Green
            }
        }
    }.GetNewClosure()
}
