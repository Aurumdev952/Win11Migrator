<#
========================================================================================================
    Title:          Win11Migrator - Migration Completion Report Generator
    Filename:       New-CompletionReport.ps1
    Description:    Generates an HTML summary report of the entire migration with success/failure details.
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
    Generates an HTML completion report summarising the entire migration.
.DESCRIPTION
    Accepts a MigrationManifest with final statuses for all items and produces a
    self-contained HTML report. Sections include Applications, User Data, Browser
    Profiles, and System Settings. Each section shows a status table and the overall
    summary includes CSS-only pie charts for visual status breakdown.
.PARAMETER Manifest
    The fully-populated MigrationManifest object with final statuses.
.PARAMETER OutputDirectory
    Directory where the HTML report will be saved. Defaults to the migration
    package directory.
.PARAMETER TargetComputer
    Name of the target computer. Defaults to the current machine name.
.OUTPUTS
    [string] Full path to the generated HTML report file.
.EXAMPLE
    $path = New-CompletionReport -Manifest $manifest -OutputDirectory "C:\MigrationPackage"
#>

function New-CompletionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationManifest]$Manifest,

        [Parameter()]
        [string]$OutputDirectory,

        [Parameter()]
        [string]$TargetComputer = $env:COMPUTERNAME
    )

    Write-MigrationLog -Message "Generating migration completion report..." -Level Info

    # Resolve output directory
    if (-not $OutputDirectory) {
        if ($script:Config -and $script:Config.PackagePath) {
            $OutputDirectory = $script:Config.PackagePath
        } else {
            $OutputDirectory = Join-Path $env:TEMP 'Win11Migrator'
        }
    }

    if (-not (Test-Path $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    }

    $exportDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $sourceComputer = if ($Manifest.SourceComputerName) { $Manifest.SourceComputerName } else { 'Unknown' }

    # Load template
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not $scriptDir) {
        $scriptDir = if ($script:MigratorRoot) {
            Join-Path $script:MigratorRoot 'Reports'
        } else {
            $PSScriptRoot
        }
    }
    $templatePath = Join-Path $scriptDir 'Templates\CompletionReport.html'
    if (-not (Test-Path $templatePath)) {
        throw "CompletionReport template not found at: $templatePath"
    }
    $template = Get-Content $templatePath -Raw -Encoding UTF8

    # ---------------------------------------------------------------
    # Helper: build a CSS conic-gradient pie chart
    # ---------------------------------------------------------------
    function Build-PieChartHtml {
        param(
            [string]$Title,
            [int]$SuccessCount,
            [int]$FailedCount,
            [int]$ManualCount,
            [int]$SkippedCount,
            [int]$PendingCount
        )

        $total = $SuccessCount + $FailedCount + $ManualCount + $SkippedCount + $PendingCount
        if ($total -eq 0) {
            return "<div class=`"chart-card`"><h3>$Title</h3><p style=`"color:#8b949e;padding:40px 0;`">No items</p></div>"
        }

        # Calculate percentages cumulatively for conic-gradient stops
        $pctSuccess = [math]::Round(($SuccessCount / $total) * 100, 1)
        $pctFailed  = [math]::Round(($FailedCount  / $total) * 100, 1)
        $pctManual  = [math]::Round(($ManualCount  / $total) * 100, 1)
        $pctSkipped = [math]::Round(($SkippedCount / $total) * 100, 1)
        $pctPending = [math]::Round(($PendingCount / $total) * 100, 1)

        # Cumulative stops
        $stop1 = $pctSuccess
        $stop2 = $stop1 + $pctFailed
        $stop3 = $stop2 + $pctManual
        $stop4 = $stop3 + $pctSkipped
        # remainder is Pending

        $gradient = "conic-gradient(" +
            "#28a745 0% ${stop1}%, " +
            "#dc3545 ${stop1}% ${stop2}%, " +
            "#ffc107 ${stop2}% ${stop3}%, " +
            "#6c757d ${stop3}% ${stop4}%, " +
            "#adb5bd ${stop4}% 100%)"

        $html = @"
            <div class="chart-card">
                <h3>$Title</h3>
                <div class="pie-container" style="background: $gradient;">
                    <div class="pie-center">$total</div>
                </div>
                <div class="chart-legend">
                    <div class="legend-item"><span class="legend-dot color-success"></span> Success ($SuccessCount)</div>
                    <div class="legend-item"><span class="legend-dot color-failed"></span> Failed ($FailedCount)</div>
                    <div class="legend-item"><span class="legend-dot color-manual"></span> Manual ($ManualCount)</div>
                    <div class="legend-item"><span class="legend-dot color-skipped"></span> Skipped ($SkippedCount)</div>
                </div>
            </div>
"@
        return $html
    }

    # ---------------------------------------------------------------
    # Helper: map status string to badge class
    # ---------------------------------------------------------------
    function Get-BadgeClass {
        param([string]$Status)
        switch ($Status) {
            'Success'  { return 'badge-success' }
            'Failed'   { return 'badge-failed'  }
            'Manual'   { return 'badge-manual'  }
            'Skipped'  { return 'badge-skipped' }
            default    { return 'badge-pending' }
        }
    }

    function Get-SafeHtml {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        return [System.Net.WebUtility]::HtmlEncode($Text)
    }

    # ---------------------------------------------------------------
    # App stats
    # ---------------------------------------------------------------
    $appTotal   = $Manifest.Apps.Count
    $appSuccess = @($Manifest.Apps | Where-Object { $_.InstallStatus -eq 'Success' }).Count
    $appFailed  = @($Manifest.Apps | Where-Object { $_.InstallStatus -eq 'Failed' }).Count
    $appManual  = @($Manifest.Apps | Where-Object { $_.InstallMethod -eq 'Manual' -and $_.InstallStatus -ne 'Failed' }).Count
    $appSkipped = @($Manifest.Apps | Where-Object { $_.InstallStatus -eq 'Skipped' -or -not $_.Selected }).Count
    $appPending = $appTotal - $appSuccess - $appFailed - $appManual - $appSkipped
    if ($appPending -lt 0) { $appPending = 0 }

    # Data stats
    $dataTotal   = $Manifest.UserData.Count
    # The report describes the import, so its status wins; ExportStatus covers items never imported
    $restoreStatus = { param($x) if ($x.ImportStatus) { $x.ImportStatus } else { $x.ExportStatus } }
    $dataSuccess = @($Manifest.UserData | Where-Object { (& $restoreStatus $_) -eq 'Success' }).Count
    $dataFailed  = @($Manifest.UserData | Where-Object { (& $restoreStatus $_) -eq 'Failed' }).Count
    $dataSkipped = @($Manifest.UserData | Where-Object { (& $restoreStatus $_) -eq 'Skipped' -or -not $_.Selected }).Count
    $dataPending = $dataTotal - $dataSuccess - $dataFailed - $dataSkipped
    if ($dataPending -lt 0) { $dataPending = 0 }

    # Browser stats
    $browserTotal   = $Manifest.BrowserProfiles.Count
    $browserSuccess = @($Manifest.BrowserProfiles | Where-Object { (& $restoreStatus $_) -eq 'Success' }).Count
    $browserFailed  = @($Manifest.BrowserProfiles | Where-Object { (& $restoreStatus $_) -eq 'Failed' }).Count
    $browserSkipped = @($Manifest.BrowserProfiles | Where-Object { (& $restoreStatus $_) -eq 'Skipped' -or -not $_.Selected }).Count
    $browserPending = $browserTotal - $browserSuccess - $browserFailed - $browserSkipped
    if ($browserPending -lt 0) { $browserPending = 0 }

    # Settings stats
    $settingsTotal   = $Manifest.SystemSettings.Count
    $settingsSuccess = @($Manifest.SystemSettings | Where-Object { $_.ImportStatus -eq 'Success' -or $_.ExportStatus -eq 'Success' }).Count
    $settingsFailed  = @($Manifest.SystemSettings | Where-Object { $_.ImportStatus -eq 'Failed' -or $_.ExportStatus -eq 'Failed' }).Count
    $settingsSkipped = @($Manifest.SystemSettings | Where-Object { $_.ImportStatus -eq 'Skipped' -or $_.ExportStatus -eq 'Skipped' -or -not $_.Selected }).Count
    $settingsPending = $settingsTotal - $settingsSuccess - $settingsFailed - $settingsSkipped
    if ($settingsPending -lt 0) { $settingsPending = 0 }

    # Overall totals
    $overallTotal   = $appTotal + $dataTotal + $browserTotal + $settingsTotal
    $overallSuccess = $appSuccess + $dataSuccess + $browserSuccess + $settingsSuccess
    $overallFailed  = $appFailed + $dataFailed + $browserFailed + $settingsFailed

    # ---------------------------------------------------------------
    # Build summary stats HTML
    # ---------------------------------------------------------------
    $summaryStatsHtml = @"
        <div class="stats-grid">
            <div class="stat-card stat-total">
                <div class="stat-value">$overallTotal</div>
                <div class="stat-label">Total Items</div>
            </div>
            <div class="stat-card stat-success">
                <div class="stat-value">$overallSuccess</div>
                <div class="stat-label">Successful</div>
            </div>
            <div class="stat-card stat-failed">
                <div class="stat-value">$overallFailed</div>
                <div class="stat-label">Failed</div>
            </div>
            <div class="stat-card stat-manual">
                <div class="stat-value">$appManual</div>
                <div class="stat-label">Manual (Apps)</div>
            </div>
            <div class="stat-card stat-skipped">
                <div class="stat-value">$($appSkipped + $dataSkipped + $browserSkipped + $settingsSkipped)</div>
                <div class="stat-label">Skipped</div>
            </div>
        </div>
"@

    # ---------------------------------------------------------------
    # Build pie charts
    # ---------------------------------------------------------------
    $chartHtml = [System.Text.StringBuilder]::new()
    [void]$chartHtml.Append((Build-PieChartHtml -Title "Applications ($appTotal)" `
        -SuccessCount $appSuccess -FailedCount $appFailed -ManualCount $appManual `
        -SkippedCount $appSkipped -PendingCount $appPending))
    [void]$chartHtml.Append((Build-PieChartHtml -Title "User Data ($dataTotal)" `
        -SuccessCount $dataSuccess -FailedCount $dataFailed -ManualCount 0 `
        -SkippedCount $dataSkipped -PendingCount $dataPending))
    [void]$chartHtml.Append((Build-PieChartHtml -Title "Browser Profiles ($browserTotal)" `
        -SuccessCount $browserSuccess -FailedCount $browserFailed -ManualCount 0 `
        -SkippedCount $browserSkipped -PendingCount $browserPending))
    [void]$chartHtml.Append((Build-PieChartHtml -Title "System Settings ($settingsTotal)" `
        -SuccessCount $settingsSuccess -FailedCount $settingsFailed -ManualCount 0 `
        -SkippedCount $settingsSkipped -PendingCount $settingsPending))

    # ---------------------------------------------------------------
    # Build Apps table
    # ---------------------------------------------------------------
    $appHtml = [System.Text.StringBuilder]::new()
    if ($Manifest.Apps.Count -gt 0) {
        [void]$appHtml.AppendLine('<table class="data-table">')
        [void]$appHtml.AppendLine('  <thead><tr><th>#</th><th>Application</th><th>Version</th><th>Publisher</th><th>Install Method</th><th>Status</th></tr></thead>')
        [void]$appHtml.AppendLine('  <tbody>')
        $i = 0
        foreach ($app in $Manifest.Apps) {
            $i++
            $status = if ($app.InstallStatus) { $app.InstallStatus } else { 'Pending' }
            # Treat Manual method apps without a failure as Manual status for badge purposes
            $badgeStatus = if ($app.InstallMethod -eq 'Manual' -and $status -ne 'Failed') { 'Manual' } else { $status }
            $badgeClass = Get-BadgeClass -Status $badgeStatus
            $errorNote = ''
            if ($app.InstallStatus -eq 'Failed' -and $app.InstallError) {
                $errorNote = "<br><small style=`"color:#6c757d;`">$(Get-SafeHtml $app.InstallError)</small>"
            }
            [void]$appHtml.AppendLine("    <tr>")
            [void]$appHtml.AppendLine("      <td>$i</td>")
            [void]$appHtml.AppendLine("      <td><strong>$(Get-SafeHtml $app.Name)</strong></td>")
            [void]$appHtml.AppendLine("      <td>$(Get-SafeHtml $app.Version)</td>")
            [void]$appHtml.AppendLine("      <td>$(Get-SafeHtml $app.Publisher)</td>")
            [void]$appHtml.AppendLine("      <td>$(Get-SafeHtml $app.InstallMethod)</td>")
            [void]$appHtml.AppendLine("      <td><span class=`"status-badge $badgeClass`">$badgeStatus</span>$errorNote</td>")
            [void]$appHtml.AppendLine("    </tr>")
        }
        [void]$appHtml.AppendLine('  </tbody>')
        [void]$appHtml.AppendLine('</table>')
    } else {
        [void]$appHtml.AppendLine('<p style="color:#8b949e;padding:16px 0;">No applications in manifest.</p>')
    }

    # ---------------------------------------------------------------
    # Build User Data table
    # ---------------------------------------------------------------
    $dataHtml = [System.Text.StringBuilder]::new()
    if ($Manifest.UserData.Count -gt 0) {
        [void]$dataHtml.AppendLine('<table class="data-table">')
        [void]$dataHtml.AppendLine('  <thead><tr><th>#</th><th>Category</th><th>Path</th><th>Size</th><th>Status</th></tr></thead>')
        [void]$dataHtml.AppendLine('  <tbody>')
        $i = 0
        foreach ($item in $Manifest.UserData) {
            $i++
            $status = if (& $restoreStatus $item) { & $restoreStatus $item } else { 'Pending' }
            $badgeClass = Get-BadgeClass -Status $status
            $sizeMB = if ($item.SizeBytes -gt 0) {
                "{0:N1} MB" -f ($item.SizeBytes / 1MB)
            } else {
                '--'
            }
            [void]$dataHtml.AppendLine("    <tr>")
            [void]$dataHtml.AppendLine("      <td>$i</td>")
            [void]$dataHtml.AppendLine("      <td>$(Get-SafeHtml $item.Category)</td>")
            [void]$dataHtml.AppendLine("      <td>$(Get-SafeHtml $item.RelativePath)</td>")
            [void]$dataHtml.AppendLine("      <td>$sizeMB</td>")
            [void]$dataHtml.AppendLine("      <td><span class=`"status-badge $badgeClass`">$status</span></td>")
            [void]$dataHtml.AppendLine("    </tr>")
        }
        [void]$dataHtml.AppendLine('  </tbody>')
        [void]$dataHtml.AppendLine('</table>')
    } else {
        [void]$dataHtml.AppendLine('<p style="color:#8b949e;padding:16px 0;">No user data items in manifest.</p>')
    }

    # ---------------------------------------------------------------
    # Build Browser Profiles table
    # ---------------------------------------------------------------
    $browserHtml = [System.Text.StringBuilder]::new()
    if ($Manifest.BrowserProfiles.Count -gt 0) {
        [void]$browserHtml.AppendLine('<table class="data-table">')
        [void]$browserHtml.AppendLine('  <thead><tr><th>#</th><th>Browser</th><th>Profile</th><th>Bookmarks</th><th>Extensions</th><th>Status</th></tr></thead>')
        [void]$browserHtml.AppendLine('  <tbody>')
        $i = 0
        foreach ($bp in $Manifest.BrowserProfiles) {
            $i++
            $status = if (& $restoreStatus $bp) { & $restoreStatus $bp } else { 'Pending' }
            $badgeClass = Get-BadgeClass -Status $status
            $bookmarks  = if ($bp.HasBookmarks)  { 'Yes' } else { 'No' }
            $extCount   = if ($bp.Extensions) { $bp.Extensions.Count.ToString() } else { '0' }
            [void]$browserHtml.AppendLine("    <tr>")
            [void]$browserHtml.AppendLine("      <td>$i</td>")
            [void]$browserHtml.AppendLine("      <td>$(Get-SafeHtml $bp.Browser)</td>")
            [void]$browserHtml.AppendLine("      <td>$(Get-SafeHtml $bp.ProfileName)</td>")
            [void]$browserHtml.AppendLine("      <td>$bookmarks</td>")
            [void]$browserHtml.AppendLine("      <td>$extCount extension(s)</td>")
            [void]$browserHtml.AppendLine("      <td><span class=`"status-badge $badgeClass`">$status</span></td>")
            [void]$browserHtml.AppendLine("    </tr>")
        }
        [void]$browserHtml.AppendLine('  </tbody>')
        [void]$browserHtml.AppendLine('</table>')
    } else {
        [void]$browserHtml.AppendLine('<p style="color:#8b949e;padding:16px 0;">No browser profiles in manifest.</p>')
    }

    # ---------------------------------------------------------------
    # Build System Settings table
    # ---------------------------------------------------------------
    $settingsHtml = [System.Text.StringBuilder]::new()
    if ($Manifest.SystemSettings.Count -gt 0) {
        [void]$settingsHtml.AppendLine('<table class="data-table">')
        [void]$settingsHtml.AppendLine('  <thead><tr><th>#</th><th>Category</th><th>Name</th><th>Export</th><th>Import</th></tr></thead>')
        [void]$settingsHtml.AppendLine('  <tbody>')
        $i = 0
        foreach ($setting in $Manifest.SystemSettings) {
            $i++
            $exportStatus = if ($setting.ExportStatus) { $setting.ExportStatus } else { 'Pending' }
            $importStatus = if ($setting.ImportStatus) { $setting.ImportStatus } else { 'Pending' }
            $exportBadge = Get-BadgeClass -Status $exportStatus
            $importBadge = Get-BadgeClass -Status $importStatus
            [void]$settingsHtml.AppendLine("    <tr>")
            [void]$settingsHtml.AppendLine("      <td>$i</td>")
            [void]$settingsHtml.AppendLine("      <td>$(Get-SafeHtml $setting.Category)</td>")
            [void]$settingsHtml.AppendLine("      <td>$(Get-SafeHtml $setting.Name)</td>")
            [void]$settingsHtml.AppendLine("      <td><span class=`"status-badge $exportBadge`">$exportStatus</span></td>")
            [void]$settingsHtml.AppendLine("      <td><span class=`"status-badge $importBadge`">$importStatus</span></td>")
            [void]$settingsHtml.AppendLine("    </tr>")
        }
        [void]$settingsHtml.AppendLine('  </tbody>')
        [void]$settingsHtml.AppendLine('</table>')
    } else {
        [void]$settingsHtml.AppendLine('<p style="color:#8b949e;padding:16px 0;">No system settings in manifest.</p>')
    }

    # ---------------------------------------------------------------
    # Assemble final HTML
    # ---------------------------------------------------------------
    $html = $template
    $html = $html.Replace('{{SOURCE_COMPUTER}}',  (Get-SafeHtml $sourceComputer))
    $html = $html.Replace('{{TARGET_COMPUTER}}',  (Get-SafeHtml $TargetComputer))
    $html = $html.Replace('{{EXPORT_DATE}}',       (Get-SafeHtml $exportDate))
    $html = $html.Replace('{{SUMMARY_STATS}}',     $summaryStatsHtml)
    $html = $html.Replace('{{CHART_SECTION}}',     $chartHtml.ToString())
    $html = $html.Replace('{{APP_SECTION}}',       $appHtml.ToString())
    $html = $html.Replace('{{DATA_SECTION}}',      $dataHtml.ToString())
    $html = $html.Replace('{{BROWSER_SECTION}}',   $browserHtml.ToString())
    $html = $html.Replace('{{SETTINGS_SECTION}}',  $settingsHtml.ToString())

    # Cross-OS Migration Notes section
    $crossOSHtml = ''
    if ($Manifest.SourceOSContext -and $Manifest.MigrationScope) {
        $sourceOS = if ($Manifest.SourceOSContext.IsWindows10) { 'Windows 10' } elseif ($Manifest.SourceOSContext.IsWindows11) { 'Windows 11' } else { 'Unknown' }
        $crossOSHtml = @"
        <div class="section">
            <h2>Cross-OS Migration Notes</h2>
            <p>Source OS: <strong>$sourceOS</strong> (Build $($Manifest.SourceOSBuild))</p>
            <ul>
                <li>Start Menu layout was not imported (layout format is incompatible between Windows 10 and Windows 11)</li>
                <li>Taskbar has been set to left-aligned to match Windows 10 familiarity</li>
                <li>File associations require manual confirmation in Settings &gt; Default Apps</li>
                <li>Default apps cannot be programmatically set on Windows 11 - please configure manually</li>
            </ul>
        </div>
"@
    }
    $html = $html.Replace('{{CROSS_OS_SECTION}}', $crossOSHtml)

    # Write output file
    $outputFile = Join-Path $OutputDirectory "CompletionReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    Set-Content -Path $outputFile -Value $html -Encoding UTF8

    Write-MigrationLog -Message "Completion report saved to $outputFile" -Level Success
    return $outputFile
}
