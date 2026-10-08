<#
========================================================================================================
    Title:          Win11Migrator - AppData Settings Importer
    Filename:       Import-AppDataSettings.ps1
    Description:    Restores application settings to AppData directories from a migration package.
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
    Restores AppData folders from a migration package to the target machine.
.DESCRIPTION
    Reads UserDataItem objects with Category 'AppData' from the manifest, locates
    the exported folders in the migration package, and restores them to the
    current user's %APPDATA% and %LOCALAPPDATA% directories.
.PARAMETER Items
    UserDataItem[] with Category 'AppData' from the migration manifest.
.PARAMETER PackagePath
    Root path of the migration package.
.OUTPUTS
    The same items with ImportStatus set.
#>

function Import-AppDataSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [switch]$MoveFromPackage,

        [hashtable]$Progress
    )

    Write-MigrationLog -Message "Beginning AppData settings import from $PackagePath" -Level Info

    $rootMap = @{
        'Roaming' = $env:APPDATA
        'Local'   = $env:LOCALAPPDATA
    }

    foreach ($item in $Items) {
        if ($item.Category -ne 'AppData') { continue }
        if (-not $item.Selected -or $item.ExportStatus -eq 'Failed') {
            $item.ImportStatus = 'Skipped'
            continue
        }

        # RelativePath is AppData\<Roaming|Local>\<folder>, relative to the package root.
        # Packages from 1.0.x nested it one level deeper, under AppData\.
        $packageSourcePath = @(
            (Join-Path $PackagePath $item.RelativePath),
            (Join-Path (Join-Path $PackagePath 'AppData') $item.RelativePath)
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $packageSourcePath) {
            $item.ImportStatus = 'Failed'
            Write-MigrationLog -Message "Package source not found for AppData item $($item.RelativePath)" -Level Warning
            continue
        }

        $pathParts = $item.RelativePath -split '[\\/]', 3
        if ($pathParts.Count -lt 3 -or -not $rootMap[$pathParts[1]]) {
            $item.ImportStatus = 'Failed'
            Write-MigrationLog -Message "Unrecognised AppData path in manifest: $($item.RelativePath)" -Level Warning
            continue
        }
        $targetPath = Join-Path $rootMap[$pathParts[1]] $pathParts[2]
        if ($Progress) { $Progress['Item'] = $item.RelativePath }

        try {
            $restore = Restore-PackageFolder -Source $packageSourcePath -Destination $targetPath -Move:$MoveFromPackage `
                -Progress $Progress -SizeHint ([long]$item.SizeBytes)
            $item.ImportStatus = if ($restore.Success) { 'Success' } else { 'Failed' }
        } catch {
            $item.ImportStatus = 'Failed'
            Write-MigrationLog -Message "Exception importing AppData $($item.RelativePath): $($_.Exception.Message)" -Level Error
        }
    }

    $appData = @($Items | Where-Object { $_.Category -eq 'AppData' })
    $successCount = @($appData | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    $failCount    = @($appData | Where-Object { $_.ImportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "AppData import complete. Success: $successCount, Failed: $failCount" -Level Info

    return $Items
}
