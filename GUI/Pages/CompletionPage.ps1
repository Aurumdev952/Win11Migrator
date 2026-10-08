<#
========================================================================================================
    Title:          Win11Migrator - Completion Page
    Filename:       CompletionPage.ps1
    Description:    Displays migration summary with success/failure counts and links to generated reports.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-CompletionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $txtCompleteTitle = $Page.FindName('txtCompleteTitle')
    $txtCompleteSubtitle = $Page.FindName('txtCompleteSubtitle')
    $iconComplete = $Page.FindName('iconComplete')
    $txtAppsSummary = $Page.FindName('txtAppsSummary')
    $txtDataSummary = $Page.FindName('txtDataSummary')
    $txtBrowserSummary = $Page.FindName('txtBrowserSummary')
    $txtSettingsSummary = $Page.FindName('txtSettingsSummary')
    $txtPackageLocation = $Page.FindName('txtPackageLocation')
    $panelReports = $Page.FindName('panelReports')
    $btnCompletionReport = $Page.FindName('btnCompletionReport')
    $btnManualReport = $Page.FindName('btnManualReport')
    $panelExportSteps = $Page.FindName('panelExportSteps')
    $panelImportSteps = $Page.FindName('panelImportSteps')
    $btnOpenFolder = $Page.FindName('btnOpenFolder')

    # Change Finish button
    $State.BtnNext.Content = "Finish"
    $State.BtnBack.Visibility = 'Collapsed'

    # Populate summary
    $selectedApps = ($State.Apps | Where-Object { $_.Selected }).Count
    $selectedData = ($State.UserData | Where-Object { $_.Selected }).Count
    $selectedBrowsers = ($State.BrowserProfiles | Where-Object { $_.Selected }).Count
    $selectedSettings = if ($State.SystemSettings) {
        @($State.SystemSettings).Count
    } else { 0 }

    $txtAppsSummary.Text = "$selectedApps"
    $txtDataSummary.Text = "$selectedData"
    $txtBrowserSummary.Text = "$selectedBrowsers"
    $txtSettingsSummary.Text = "$selectedSettings"

    if ($State.PackagePath) {
        $txtPackageLocation.Text = $State.PackagePath
    }

    # Mode-specific content
    if ($State.Mode -eq 'Import') {
        $txtCompleteTitle.Text = "Import Complete!"
        $txtCompleteSubtitle.Text = "Your apps, data, and settings have been restored."
        $panelExportSteps.Visibility = 'Collapsed'
        $panelImportSteps.Visibility = 'Visible'

        # Check for failures
        $failedApps = ($State.Apps | Where-Object { $_.InstallStatus -eq 'Failed' }).Count
        if ($failedApps -gt 0) {
            $txtCompleteSubtitle.Text = "Import completed with $failedApps app(s) needing manual attention."
            $iconComplete.Fill = $Page.FindResource('WarningBrush')
            $iconComplete.Data = $Page.FindResource('WarningIcon')
        }

        # Show reports
        if ($State.CompletionReportPath -or $State.ManualReportPath) {
            $panelReports.Visibility = 'Visible'
        }
    } else {
        $txtCompleteTitle.Text = "Export Complete!"
        $txtCompleteSubtitle.Text = "Your migration package is ready for transfer."

        # Show target-specific next-step instructions
        $exportStepsText = $null
        $storageTarget = if ($State.StorageTarget.Type) { $State.StorageTarget.Type } elseif ($State.StorageTarget -is [string]) { $State.StorageTarget } else { '' }

        switch ($storageTarget) {
            'USB' {
                $exportStepsText = @(
                    "Next steps to restore on your new PC:",
                    "1. Plug the USB drive into your new PC",
                    "2. Open the Win11Migrator folder on the USB drive",
                    "3. Double-click Win11Migrator.bat",
                    "4. The import wizard will auto-detect your migration package"
                ) -join "`n"
            }
            'OneDrive' {
                $exportStepsText = @(
                    "Next steps to restore on your new PC:",
                    "1. Sign into OneDrive on your new PC",
                    "2. Wait for the Win11Migrator folder to sync",
                    "3. Open the Win11Migrator folder in OneDrive",
                    "4. Double-click Win11Migrator.bat to start the import"
                ) -join "`n"
            }
            'GoogleDrive' {
                $exportStepsText = @(
                    "Next steps to restore on your new PC:",
                    "1. Sign into Google Drive on your new PC",
                    "2. Wait for the Win11Migrator folder to sync",
                    "3. Open the Win11Migrator folder in Google Drive",
                    "4. Double-click Win11Migrator.bat to start the import"
                ) -join "`n"
            }
            'AdminShare' {
                $exportStepsText = if ($State.RemoteRestoreMessage) { $State.RemoteRestoreMessage } else {
                    "The package and Win11Migrator are in C:\Win11Migrator on the target PC. Sign in there and run Win11Migrator.bat, then choose Import."
                }
            }
            'LanReceive' {
                $exportStepsText = "Everything was sent to $($State.StorageTarget.Computer). The restore continues on that PC; follow its progress there."
            }
            'NetworkShare' {
                $exportStepsText = @(
                    "Next steps to restore on your new PC:",
                    "1. Open the Win11Migrator folder on the network share",
                    "2. Double-click Win11Migrator.bat",
                    "3. The import wizard will auto-detect your migration package"
                ) -join "`n"
            }
            default {
                $exportStepsText = @(
                    "Next steps to restore on your new PC:",
                    "1. Open the Win11Migrator folder on your export target",
                    "2. Double-click Win11Migrator.bat",
                    "3. Select Import mode and choose your migration package"
                ) -join "`n"
            }
        }

        if ($exportStepsText -and $panelExportSteps) {
            $stepsBlock = [System.Windows.Controls.TextBlock]::new()
            $stepsBlock.Text = $exportStepsText
            $stepsBlock.TextWrapping = 'Wrap'
            $stepsBlock.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            try { $stepsBlock.Style = $Page.FindResource('BodyText') } catch {}
            $null = $panelExportSteps.Children.Add($stepsBlock)
        }
    }

    # Report buttons
    $btnCompletionReport.Add_Click({
        if ($State.CompletionReportPath -and (Test-Path $State.CompletionReportPath)) {
            Start-Process $State.CompletionReportPath
        }
    }.GetNewClosure())

    $btnManualReport.Add_Click({
        if ($State.ManualReportPath -and (Test-Path $State.ManualReportPath)) {
            Start-Process $State.ManualReportPath
        }
    }.GetNewClosure())

    if ($State.ManualReportPath) {
        $btnManualReport.Visibility = 'Visible'
    }

    # Open folder button
    $btnOpenFolder.Add_Click({
        if ($State.PackagePath -and (Test-Path $State.PackagePath)) {
            Start-Process explorer.exe -ArgumentList $State.PackagePath
        }
    }.GetNewClosure())

    # Health Check button (Import mode only)
    $btnHealthCheck = $Page.FindName('btnHealthCheck')
    if ($btnHealthCheck -and $State.Mode -eq 'Import') {
        $btnHealthCheck.Visibility = 'Visible'
        $btnHealthCheck.Add_Click({
            # Defensive dot-source: ensure functions are available in closure scope
            . (Join-Path $State.MigratorRoot "Core\Invoke-HealthCheck.ps1")
            try {
                $manifest = $State.Manifest
                if (-not $manifest) {
                    [System.Windows.MessageBox]::Show("No manifest available for health check.", "Health Check", 'OK', 'Information')
                    return
                }
                $healthResult = Invoke-HealthCheck -Manifest $manifest
                $scoreText = "Health Score: $([Math]::Round($healthResult.Score, 1))% ($($healthResult.Passed) passed, $($healthResult.Failed) failed, $($healthResult.Warnings) warnings)"
                $detailLines = @($scoreText, "")
                foreach ($check in $healthResult.Checks) {
                    $icon = switch ($check.Status) { 'Pass' { '[OK]' }; 'Fail' { '[FAIL]' }; 'Warning' { '[WARN]' }; default { '[--]' } }
                    $detailLines += "$icon $($check.Name): $($check.Detail)"
                }
                [System.Windows.MessageBox]::Show(($detailLines -join "`n"), "Post-Migration Health Check", 'OK', 'Information')
            } catch {
                [System.Windows.MessageBox]::Show("Health check error: $($_.Exception.Message)", "Error", 'OK', 'Error')
            }
        }.GetNewClosure())
    }

    # Cross-OS migration notes
    if ($State.IsCrossOSMigration -and $State.Mode -eq 'Import') {
        $txtCrossOS = $Page.FindName('txtCrossOSNotes')
        if ($txtCrossOS) {
            $txtCrossOS.Visibility = 'Visible'
            $notes = @(
                "Cross-OS Migration Notes:",
                "- Start Menu layout was not imported (incompatible between Win10/Win11)",
                "- Taskbar has been set to left-aligned for familiarity",
                "- File associations may require manual confirmation in Settings > Default Apps"
            )
            $txtCrossOS.Text = $notes -join "`n"
        }
    }

    Write-MigrationLog -Message "Migration wizard completed - Mode: $($State.Mode)" -Level Success
}
