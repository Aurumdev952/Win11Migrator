<#
========================================================================================================
    Title:          Win11Migrator - Import Source Selection Page
    Filename:       ImportSourcePage.ps1
    Description:    Allows users to select a migration package source for import on the target machine.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ImportSourcePage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $txtPackagePath = $Page.FindName('txtPackagePath')
    $btnBrowsePackage = $Page.FindName('btnBrowsePackage')
    $panelDetectedSources = $Page.FindName('panelDetectedSources')
    $panelPackageInfo = $Page.FindName('panelPackageInfo')
    $txtSourceComputer = $Page.FindName('txtSourceComputer')
    $txtExportDate = $Page.FindName('txtExportDate')
    $txtSourceOS = $Page.FindName('txtSourceOS')
    $txtAppCount = $Page.FindName('txtAppCount')
    $txtDataCount = $Page.FindName('txtDataCount')
    $txtSourceUser = $Page.FindName('txtSourceUser')

    $State.BtnNext.IsEnabled = $false

    $loadManifest = {
        param([string]$PkgPath)

        # Defensive dot-source: ensure functions are available in closure scope
        . (Join-Path $State.MigratorRoot "Core\Write-MigrationLog.ps1")
        . (Join-Path $State.MigratorRoot "Core\Read-MigrationManifest.ps1")

        . (Join-Path $State.MigratorRoot "Core\Unprotect-MigrationPackage.ps1")
        $encryptedFile = Find-EncryptedPackage -Path $PkgPath
        if ($encryptedFile) {
            $password = & $State.ReadPasswordDialog "Enter the password used when this package was exported:`n$encryptedFile"
            if (-not $password) { return }
            try {
                $PkgPath = Expand-EncryptedPackage -EncryptedFile $encryptedFile -Password $password -OutputRoot $State.Config.PackagePath
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Decryption failed",
                    [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                return
            }
        }

        $manifestFile = Join-Path $PkgPath "manifest.json"
        if (-not (Test-Path $manifestFile)) {
            [System.Windows.MessageBox]::Show(
                "No manifest.json found in the selected folder.`nPlease select the root folder of a Win11Migrator package.",
                "Invalid Package",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            )
            return
        }

        try {
            $manifest = Read-MigrationManifest -ManifestPath $manifestFile
            $State.Manifest = $manifest
            $State.PackagePath = $PkgPath
            $State.Apps = $manifest.Apps
            $State.UserData = $manifest.UserData
            $State.BrowserProfiles = $manifest.BrowserProfiles
            $State.SystemSettings = $manifest.SystemSettings
            $State.AppProfiles = if ($manifest.AppProfiles) { $manifest.AppProfiles } else { @() }

            $txtPackagePath.Text = $PkgPath
            $panelPackageInfo.Visibility = 'Visible'
            $txtSourceComputer.Text = $manifest.SourceComputerName
            $txtExportDate.Text = $manifest.ExportDate
            $txtSourceOS.Text = $manifest.SourceOSVersion
            $txtAppCount.Text = "$($manifest.Apps.Count) applications"
            $txtDataCount.Text = "$($manifest.UserData.Count) folders, $($manifest.BrowserProfiles.Count) browser profiles, $($manifest.SystemSettings.Count) settings"
            $txtSourceUser.Text = $manifest.SourceUserName

            $State.BtnNext.IsEnabled = $true
            Write-MigrationLog -Message "Package loaded from $PkgPath" -Level Success
        } catch {
            [System.Windows.MessageBox]::Show(
                "Error reading manifest: $($_.Exception.Message)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }

    # Browse button
    $btnBrowsePackage.Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = "Select the Win11Migrator migration package folder"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            & $loadManifest $dialog.SelectedPath
        }
    }.GetNewClosure())

    # Auto-detect packages on USB drives, cloud folders, and sibling directories
    $searchPaths = @()

    # Check for migration packages adjacent to where Win11Migrator is running from
    # This handles the case where Win11Migrator was bundled alongside a package on USB/cloud
    if ($script:MigratorRoot) {
        $searchPaths += $script:MigratorRoot
        $migratorParent = Split-Path $script:MigratorRoot -Parent
        if ($migratorParent -and (Test-Path $migratorParent)) {
            $searchPaths += $migratorParent
        }
    }

    # Check USB drives
    try {
        $usbDrives = Get-USBDrives
        foreach ($drive in $usbDrives) {
            $searchPaths += "$($drive.DriveLetter.TrimEnd(':')):"
        }
    } catch {}

    # Check cloud sync folders
    try {
        $cloud = Find-CloudSyncFolders
        if ($cloud.OneDrivePath) { $searchPaths += $cloud.OneDrivePath }
        if ($cloud.GoogleDrivePath) { $searchPaths += $cloud.GoogleDrivePath }
    } catch {}

    foreach ($basePath in $searchPaths) {
        try {
            $migFolders = Get-ChildItem $basePath -Directory -Filter "Win11Migration_*" -ErrorAction SilentlyContinue
            if (-not $migFolders) {
                $migFolders = Get-ChildItem $basePath -Directory -Filter "Win11Migrator" -ErrorAction SilentlyContinue
                if ($migFolders) {
                    $migFolders = Get-ChildItem $migFolders.FullName -Directory -Filter "Win11Migration_*" -ErrorAction SilentlyContinue
                }
            }

            foreach ($folder in $migFolders) {
                $manifestCheck = Join-Path $folder.FullName "manifest.json"
                if (Test-Path $manifestCheck) {
                    $btn = [System.Windows.Controls.Button]::new()
                    $btn.Content = $folder.FullName
                    $btn.Style = $Page.FindResource('SecondaryButton')
                    $btn.HorizontalAlignment = 'Left'
                    $btn.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
                    $btn.Tag = $folder.FullName
                    $btn.Add_Click({
                        & $loadManifest $this.Tag
                    }.GetNewClosure())
                    $null = $panelDetectedSources.Children.Add($btn)
                }
            }
        } catch {}
    }

    if ($panelDetectedSources.Children.Count -eq 0) {
        $noPackages = [System.Windows.Controls.TextBlock]::new()
        $noPackages.Text = "No migration packages detected. Use Browse to locate your package."
        $noPackages.Style = $Page.FindResource('CaptionText')
        $null = $panelDetectedSources.Children.Add($noPackages)
    }
}
