<#
========================================================================================================
    Title:          Win11Migrator - Manual Install Report Generator
    Filename:       New-ManualInstallReport.ps1
    Description:    Generates an HTML report listing applications that require manual installation.
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
    Generates an HTML report listing applications that require manual installation.
.DESCRIPTION
    Accepts an array of MigrationApp objects and filters to those with InstallMethod
    equal to 'Manual' or InstallStatus equal to 'Failed'. Produces a self-contained HTML
    file using the ManualInstallReport.html template, listing each application with its
    name, version, publisher, reason for manual action, and download URL if available.
.PARAMETER Apps
    Array of MigrationApp objects from the migration manifest.
.PARAMETER OutputDirectory
    Directory where the HTML report file will be saved. Defaults to the migration
    package directory.
.PARAMETER SourceComputer
    Name of the source computer. Defaults to the current machine name.
.PARAMETER ExportDate
    Timestamp string for the report header. Defaults to the current date/time.
.OUTPUTS
    [string] Full path to the generated HTML report file.
.EXAMPLE
    $path = New-ManualInstallReport -Apps $manifest.Apps -OutputDirectory "C:\MigrationPackage"
#>

function New-ManualInstallReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [MigrationApp[]]$Apps,

        [Parameter()]
        [string]$OutputDirectory,

        [Parameter()]
        [string]$SourceComputer = $env:COMPUTERNAME,

        [Parameter()]
        [string]$ExportDate
    )

    Write-MigrationLog -Message "Generating manual-install report..." -Level Info

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

    # Resolve export date
    if (-not $ExportDate) {
        $ExportDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    # Filter to manual / failed apps
    $manualApps = @($Apps | Where-Object {
        $_.InstallMethod -eq 'Manual' -or $_.InstallStatus -eq 'Failed'
    })

    Write-MigrationLog -Message "Found $($manualApps.Count) app(s) requiring manual installation" -Level Info

    # Load template
    # Inside a function MyInvocation.MyCommand.Definition is the function's source, not its path;
    # $PSScriptRoot is the folder of the file that defines the function
    $scriptDir = $PSScriptRoot
    $templatePath = Join-Path $scriptDir 'Templates\ManualInstallReport.html'
    if (-not (Test-Path $templatePath)) {
        throw "ManualInstallReport template not found at: $templatePath"
    }
    $template = Get-Content $templatePath -Raw -Encoding UTF8

    # Build table rows
    $rowsHtml = [System.Text.StringBuilder]::new()
    $index = 0
    foreach ($app in $manualApps) {
        $index++

        # Determine reason
        $reason = if ($app.InstallStatus -eq 'Failed') {
            'Installation Failed'
        } else {
            'Manual Install Only'
        }

        $reasonClass = if ($app.InstallStatus -eq 'Failed') {
            'reason-failed'
        } else {
            'reason-manual'
        }

        # Sanitize values for HTML
        $safeName      = [System.Net.WebUtility]::HtmlEncode($app.Name)
        $safeVersion   = [System.Net.WebUtility]::HtmlEncode($app.Version)
        $safePublisher = [System.Net.WebUtility]::HtmlEncode($app.Publisher)

        # Build download cell
        $downloadCell = if ($app.DownloadUrl) {
            $safeUrl = [System.Net.WebUtility]::HtmlEncode($app.DownloadUrl)
            "<a class=`"download-link`" href=`"$safeUrl`" target=`"_blank`">Download</a>"
        } else {
            '<span class="no-url">Not available</span>'
        }

        # Build error detail if failed
        $reasonDisplay = "<span class=`"reason-tag $reasonClass`">$reason</span>"
        if ($app.InstallStatus -eq 'Failed' -and $app.InstallError) {
            $safeError = [System.Net.WebUtility]::HtmlEncode($app.InstallError)
            $reasonDisplay += "<br><small style=`"color:#6c757d;`">$safeError</small>"
        }

        [void]$rowsHtml.AppendLine("                <tr>")
        [void]$rowsHtml.AppendLine("                    <td>$index</td>")
        [void]$rowsHtml.AppendLine("                    <td><strong>$safeName</strong></td>")
        [void]$rowsHtml.AppendLine("                    <td>$safeVersion</td>")
        [void]$rowsHtml.AppendLine("                    <td>$safePublisher</td>")
        [void]$rowsHtml.AppendLine("                    <td>$reasonDisplay</td>")
        [void]$rowsHtml.AppendLine("                    <td>$downloadCell</td>")
        [void]$rowsHtml.AppendLine("                </tr>")
    }

    # Handle empty list
    if ($manualApps.Count -eq 0) {
        [void]$rowsHtml.AppendLine('                <tr><td colspan="6" style="text-align:center;color:#6c757d;padding:24px;">No applications require manual installation.</td></tr>')
    }

    # Replace placeholders
    $html = $template
    $html = $html.Replace('{{APP_ROWS}}', $rowsHtml.ToString())
    $html = $html.Replace('{{TOTAL_COUNT}}', $manualApps.Count.ToString())
    $html = $html.Replace('{{EXPORT_DATE}}', [System.Net.WebUtility]::HtmlEncode($ExportDate))
    $html = $html.Replace('{{SOURCE_COMPUTER}}', [System.Net.WebUtility]::HtmlEncode($SourceComputer))

    # Write output file
    $outputFile = Join-Path $OutputDirectory "ManualInstallReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    Set-Content -Path $outputFile -Value $html -Encoding UTF8

    Write-MigrationLog -Message "Manual-install report saved to $outputFile" -Level Success
    return $outputFile
}
