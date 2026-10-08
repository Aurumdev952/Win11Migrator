<#
========================================================================================================
    Title:          Win11Migrator - Import Engine
    Filename:       Invoke-MigrationImport.ps1
    Description:    The one restore pipeline shared by the GUI, the CLI and network receives. Applications
                    install in a background runspace while files are restored, so the two overlap.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

$script:SettingsImportTable = @(
    @{ Category = 'WiFi';           Func = 'Import-WiFiProfiles';          Sub = 'WiFi' }
    @{ Category = 'Printer';        Func = 'Import-PrinterConfigs';        Sub = $null }
    @{ Category = 'MappedDrive';    Func = 'Import-MappedDrives';          Sub = $null }
    @{ Category = 'EnvVar';         Func = 'Import-EnvironmentVariables';  Sub = $null }
    @{ Category = 'WindowsSetting'; Func = 'Import-WindowsSettings';       Sub = 'WindowsSettings'; CrossOS = $true }
    @{ Category = 'Accessibility';  Func = 'Import-AccessibilitySettings'; Sub = 'Accessibility' }
    @{ Category = 'Regional';       Func = 'Import-RegionalSettings';      Sub = 'Regional' }
    @{ Category = 'VPN';            Func = 'Import-VPNConnections';        Sub = 'VPN' }
    @{ Category = 'Certificate';    Func = 'Import-UserCertificates';      Sub = 'Certificates' }
    @{ Category = 'ODBC';           Func = 'Import-ODBCSettings';          Sub = 'ODBC' }
    @{ Category = 'FolderOption';   Func = 'Import-FolderOptions';         Sub = 'FolderOptions' }
    @{ Category = 'InputSetting';   Func = 'Import-InputSettings';         Sub = 'InputSettings' }
    @{ Category = 'PowerPlan';      Func = 'Import-PowerSettings';         Sub = 'PowerPlan' }
)

function Get-ImportWorkPath {
    <#
    .SYNOPSIS
        Folder for reports and the rollback snapshot: the package itself when writable,
        otherwise a local folder (packages on read-only media or a share without write access).
    #>
    param([Parameter(Mandatory)][string]$PackagePath, [string]$LocalRoot = $script:Config.PackagePath)
    $probe = Join-Path $PackagePath ".write-test-$([guid]::NewGuid().ToString('N'))"
    try {
        Set-Content -Path $probe -Value '' -ErrorAction Stop
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
        return $PackagePath
    } catch {
        $local = Join-Path $LocalRoot "Import_$(Split-Path $PackagePath -Leaf)"
        New-Item -Path $local -ItemType Directory -Force | Out-Null
        return $local
    }
}

function Get-AppsToInstall {
    param($Apps)
    return @($Apps | Where-Object { $_.Selected -and $_.InstallMethod -and $_.InstallMethod -ne 'Manual' -and $_.InstallStatus -ne 'Success' })
}

function Start-AppInstallWorker {
    <#
    .SYNOPSIS
        Starts Invoke-AppInstallPipeline in its own runspace and returns a handle for Wait-AppInstallWorker.
        Progress gets AppsTotal, AppsDone, AppsFailed and AppItem as installs proceed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Apps,
        [Parameter(Mandatory)][hashtable]$Progress,
        $Config = $script:Config,
        [string]$MigratorRoot = $script:MigratorRoot
    )

    # Plain property bags convert into the worker runspace's own MigrationApp class
    $plainApps = @(Get-AppsToInstall $Apps | Select-Object *)
    $Progress['AppsTotal'] = $plainApps.Count
    $Progress['AppsDone'] = 0
    $Progress['AppsFailed'] = 0

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript({
        param($Apps, $Config, $Root, $Progress)
        foreach ($core in 'Initialize-Environment', 'Write-MigrationLog', 'Invoke-WithRetry') { . (Join-Path $Root "Core/$core.ps1") }
        foreach ($module in 'AppDiscovery', 'AppInstaller') {
            Get-ChildItem (Join-Path $Root "Modules/$module/*.ps1") | ForEach-Object { . $_.FullName }
        }
        $script:Config = $Config
        $script:MigratorRoot = $Root
        if ($Apps.Count -eq 0) { return @() }
        $configTable = if ($Config -is [hashtable]) { $Config } else { @{} }
        # Closure: the pipeline's own $progress variable would otherwise shadow ours (names are case-insensitive)
        $onProgress = {
            param($p)
            $Progress['AppsDone'] = $p.CompletedItems
            $Progress['AppsFailed'] = $p.FailedItems
            $Progress['AppItem'] = $p.StatusMessage
        }.GetNewClosure()
        Invoke-AppInstallPipeline -Apps $Apps -Config $configTable -OnProgress $onProgress
    }).AddArgument($plainApps).AddArgument($Config).AddArgument($MigratorRoot).AddArgument($Progress)

    return @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Runspace = $runspace }
}

function Wait-AppInstallWorker {
    param([Parameter(Mandatory)][hashtable]$Worker)
    try {
        return @($Worker.PowerShell.EndInvoke($Worker.Handle))
    } finally {
        $Worker.PowerShell.Dispose()
        $Worker.Runspace.Dispose()
    }
}

function Merge-InstallResults {
    # The pipeline returns new objects; copy their outcome onto the manifest's full app list
    # so reports still show manual and unselected apps.
    param($Apps, $Results)
    $byName = @{}
    foreach ($r in $Results) { if ($r.Name) { $byName[$r.Name] = $r } }
    foreach ($app in $Apps) {
        $r = $byName[$app.Name]
        if ($r) {
            $app.InstallStatus = $r.InstallStatus
            $app.InstallError = $r.InstallError
        }
    }
}

function Invoke-MigrationImport {
    <#
    .SYNOPSIS
        Restores a migration package onto this PC.
    .PARAMETER Manifest
        Output of Read-MigrationManifest.
    .PARAMETER AppWorker
        An install worker already started (Receive mode starts installs while data is still arriving).
    .PARAMETER MoveFromPackage
        Consume the package by renaming folders into place; for packages received over the network.
    .PARAMETER Progress
        Synchronized hashtable: Phase, Percent, Item, Log, Succeeded, Failed, BytesTotal, BytesDone,
        AppsTotal, AppsDone, Echo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)]$Manifest,
        [hashtable]$Progress = [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) }),
        [hashtable]$AppWorker,
        [switch]$MoveFromPackage
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $succeeded = 0
    $failed = 0
    $workPath = Get-ImportWorkPath -PackagePath $PackagePath
    $userData = @($Manifest.UserData)
    $toRestore = @($userData | Where-Object { $_.Selected -and $_.ExportStatus -notin 'Skipped', 'Failed' })
    $Progress['BytesTotal'] = [long](($toRestore | Measure-Object -Property SizeBytes -Sum).Sum)
    $Progress['BytesDone'] = 0L
    $Progress['StartedUtc'] = (Get-Date).ToUniversalTime()

    $setPhase = {
        param([string]$Phase, [int]$Percent)
        $Progress['Phase'] = $Phase
        $Progress['Percent'] = $Percent
        Add-ProgressLog $Progress "[$Phase]"
    }

    & $setPhase 'Creating rollback snapshot' 1
    try {
        $profilePaths = Get-UserProfilePaths
        $targets = @($toRestore | Where-Object { $_.Category -ne 'AppData' } |
            ForEach-Object { Get-UserDataRestoreTarget -Item $_ -TargetProfilePaths $profilePaths } |
            Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
        $snapshotPath = Join-Path $workPath 'RollbackSnapshot'
        $snap = New-RollbackSnapshot -SnapshotPath $snapshotPath -UserDataPaths $targets -RegistryPaths @(
            'HKCU:\Control Panel\Accessibility',
            'HKCU:\Control Panel\International',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
            'HKCU:\Control Panel\Keyboard',
            'HKCU:\Control Panel\Mouse')
        if ($snap.Success) { $Progress['RollbackSnapshotPath'] = $snapshotPath }
    } catch {
        Add-ProgressLog $Progress "  [WARN] Rollback snapshot: $($_.Exception.Message)"
    }

    $usmtStore = Join-Path $PackagePath 'USMTStore'
    if (Test-Path $usmtStore) {
        & $setPhase 'Running USMT LoadState' 2
        try {
            $usmt = Test-USMTAvailability
            if ($usmt.Available) {
                $usmtXmls = @($usmt.MigAppXml, $usmt.MigDocsXml, $usmt.MigUserXml) | Where-Object { $_ -and (Test-Path $_) }
                $usmtResult = Invoke-USMTLoadState -LoadStatePath $usmt.LoadStatePath -StorePath $usmtStore `
                    -MigrationXmls $usmtXmls -LogPath (Join-Path $workPath 'usmt_loadstate.log')
                if (-not $usmtResult.Success) { Add-ProgressLog $Progress "  [WARN] USMT LoadState: $($usmtResult.ErrorMessage)" }
            }
        } catch {
            Add-ProgressLog $Progress "  [WARN] USMT LoadState: $($_.Exception.Message)"
        }
    }

    $crossOS = $null
    try {
        $targetOS = Get-OSMigrationContext
        $sourceOS = $Manifest.SourceOSContext
        if ($sourceOS -and (($sourceOS.IsWindows10 -and $targetOS.IsWindows11) -or ($sourceOS.IsWindows11 -and $targetOS.IsWindows10))) {
            $crossOS = @{ Source = $sourceOS; Target = $targetOS }
            Add-ProgressLog $Progress "  Cross-OS migration: $($sourceOS.DisplayVersion) to $($targetOS.DisplayVersion)"
        }
    } catch {
        Add-ProgressLog $Progress "  [WARN] OS detection: $($_.Exception.Message)"
    }

    & $setPhase 'Installing applications and restoring files' 3
    $Progress['Parallel'] = $true
    $worker = if ($AppWorker) { $AppWorker } else { Start-AppInstallWorker -Apps $Manifest.Apps -Progress $Progress }

    try {
        Import-UserProfile -Items $userData -PackagePath $PackagePath -MoveFromPackage:$MoveFromPackage -Progress $Progress `
            -TargetProfilePaths $profilePaths -PreserveACLs:([bool](Get-MigrationSetting $script:Config 'PreserveACLs' $false)) | Out-Null
        Import-AppDataSettings -Items $userData -PackagePath $PackagePath -MoveFromPackage:$MoveFromPackage -Progress $Progress | Out-Null
    } catch {
        $errors.Add("UserData: $($_.Exception.Message)")
    }
    $succeeded += @($userData | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    $failed += @($userData | Where-Object { $_.ImportStatus -eq 'Failed' }).Count
    $Progress['Succeeded'] = $succeeded
    $Progress['Failed'] = $failed

    $Progress['Phase'] = 'Waiting for application installs to finish'
    try {
        $installed = Wait-AppInstallWorker -Worker $worker
        Merge-InstallResults -Apps $Manifest.Apps -Results $installed
    } catch {
        $errors.Add("AppInstall: $($_.Exception.Message)")
    }
    $succeeded += @($Manifest.Apps | Where-Object { $_.InstallStatus -eq 'Success' }).Count
    $failed += @($Manifest.Apps | Where-Object { $_.InstallStatus -eq 'Failed' }).Count
    $Progress['Parallel'] = $false
    $Progress['Succeeded'] = $succeeded
    $Progress['Failed'] = $failed

    # Browsers and settings come after installs: a browser restore needs the browser present
    & $setPhase 'Restoring browser profiles' 75
    $browserDir = Join-Path $PackagePath 'BrowserProfiles'
    foreach ($bp in @($Manifest.BrowserProfiles | Where-Object { $_.Selected })) {
        $profileDir = Join-Path $browserDir "$($bp.Browser)_$($bp.ProfileName)"
        if (-not (Test-Path $profileDir)) { continue }
        $Progress['Item'] = "$($bp.Browser) - $($bp.ProfileName)"
        try {
            switch ($bp.Browser) {
                'Chrome'  { Import-ChromeProfile -Profile $bp -PackagePath $profileDir | Out-Null }
                'Edge'    { Import-EdgeProfile -Profile $bp -PackagePath $profileDir | Out-Null }
                'Firefox' { Import-FirefoxProfile -Profile $bp -PackagePath $profileDir | Out-Null }
                'Brave'   { Import-BraveProfile -Profile $bp -PackagePath $profileDir | Out-Null }
            }
            $bp.ImportStatus = 'Success'
            $succeeded++
        } catch {
            $bp.ImportStatus = 'Failed'
            $failed++
            $errors.Add("Browser $($bp.Browser): $($_.Exception.Message)")
        }
    }

    & $setPhase 'Restoring system settings' 82
    $settingsDir = Join-Path $PackagePath 'SystemSettings'
    foreach ($entry in $script:SettingsImportTable) {
        $settings = @($Manifest.SystemSettings | Where-Object { $_.Category -eq $entry.Category -and $_.Selected })
        if ($settings.Count -eq 0) { continue }
        $Progress['Item'] = $entry.Category
        try {
            if ($entry.CrossOS -and $crossOS) {
                $converted = Convert-CrossOSSettings -SourceOSContext $crossOS.Source -TargetOSContext $crossOS.Target -Settings $settings
                $settings = @($converted.Settings)
                foreach ($w in $converted.Warnings) { Add-ProgressLog $Progress "  [CROSS-OS] $w" }
            }
            $splat = @{ Settings = $settings }
            if ($entry.Sub) { $splat['PackagePath'] = Join-Path $settingsDir $entry.Sub }
            & $entry.Func @splat | Out-Null
        } catch {
            $errors.Add("$($entry.Category): $($_.Exception.Message)")
        }
    }
    $succeeded += @($Manifest.SystemSettings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    $failed += @($Manifest.SystemSettings | Where-Object { $_.ImportStatus -eq 'Failed' }).Count

    $profilesDir = Join-Path $PackagePath 'AppProfiles'
    if ((Test-Path $profilesDir) -and @($Manifest.AppProfiles).Count -gt 0) {
        & $setPhase 'Restoring application profiles' 90
        try {
            $succeeded += [int](Import-AppProfiles -SourcePath $profilesDir -Profiles $Manifest.AppProfiles)
        } catch {
            $errors.Add("AppProfiles: $($_.Exception.Message)")
        }
    }

    & $setPhase 'Generating reports' 95
    $reportDir = Join-Path $workPath 'Reports'
    $reports = @{}
    try {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        $manualApps = @($Manifest.Apps | Where-Object { $_.InstallMethod -eq 'Manual' -or $_.InstallStatus -eq 'Failed' })
        if ($manualApps.Count -gt 0) { $reports['Manual'] = New-ManualInstallReport -Apps $manualApps -OutputDirectory $reportDir }
        $reports['Completion'] = New-CompletionReport -Manifest $Manifest -OutputDirectory $reportDir
    } catch {
        $errors.Add("Reports: $($_.Exception.Message)")
    }

    $Progress['Succeeded'] = $succeeded
    $Progress['Failed'] = $failed
    $Progress['Percent'] = 100
    $Progress['Phase'] = 'Import complete'
    $Progress['Item'] = ''

    return [PSCustomObject]@{
        Succeeded            = $succeeded
        Failed               = $failed
        Errors               = $errors.ToArray()
        WorkPath             = $workPath
        CompletionReportPath = $reports['Completion']
        ManualReportPath     = $reports['Manual']
        RollbackSnapshotPath = $Progress['RollbackSnapshotPath']
    }
}
