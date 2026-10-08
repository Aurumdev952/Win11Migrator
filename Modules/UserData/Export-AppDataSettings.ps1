<#
========================================================================================================
    Title:          Win11Migrator - AppData Settings Exporter
    Filename:       Export-AppDataSettings.ps1
    Description:    Exports application settings from AppData (Local/Roaming) directories for migration.
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
    Exports selected AppData folders for migration.
.DESCRIPTION
    Copies folders listed in the AppDataInclude configuration from both
    %APPDATA% (Roaming) and %LOCALAPPDATA% (Local) to the migration package.
    Returns UserDataItem[] representing what was exported.
.PARAMETER AppDataFolders
    Array of relative AppData folder paths to export. If not specified, reads
    from the AppDataInclude config setting.
.PARAMETER OutputDirectory
    Root of the migration package.
.OUTPUTS
    [UserDataItem[]] Items representing exported AppData settings.
#>

function Export-AppDataSettings {
    [CmdletBinding()]
    param(
        [string[]]$AppDataFolders,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [hashtable]$Exclusions = (Get-MigrationExclusions),

        [ValidateSet('Local', 'USB', 'Network', 'Cloud')]
        [string]$TargetKind = 'Local',

        [hashtable]$Progress
    )

    Write-MigrationLog -Message "Beginning AppData settings export" -Level Info

    if (-not $AppDataFolders) {
        $AppDataFolders = @(Get-MigrationSetting $script:Config 'AppDataInclude' @() | ForEach-Object { $_.ToString() })
    }
    if ($AppDataFolders.Count -eq 0) {
        Write-MigrationLog -Message "No AppData folders configured for export" -Level Warning
        return @()
    }

    $exportedItems = [System.Collections.Generic.List[UserDataItem]]::new()
    $appDataRoots = @(
        @{ Label = 'Roaming'; Path = $env:APPDATA }
        @{ Label = 'Local';   Path = $env:LOCALAPPDATA }
    )

    foreach ($folder in $AppDataFolders) {
        foreach ($root in $appDataRoots) {
            if (-not $root.Path) { continue }
            $sourcePath = Join-Path $root.Path $folder
            if (-not (Test-Path -LiteralPath $sourcePath)) { continue }

            # RelativePath is relative to the package root: AppData\<Roaming|Local>\<folder>
            $relativePath = Join-Path (Join-Path 'AppData' $root.Label) $folder
            $destPath = Join-Path $OutputDirectory $relativePath

            $item = [UserDataItem]::new()
            $item.SourcePath   = $sourcePath
            $item.RelativePath = $relativePath
            $item.Category     = 'AppData'
            $item.Selected     = $true
            if ($Progress) { $Progress['Item'] = "AppData\$($root.Label)\$folder" }

            try {
                $copy = Invoke-Robocopy -Source $sourcePath -Destination $destPath -TargetKind $TargetKind -Exclusions $Exclusions -Progress $Progress
                $item.SizeBytes = $copy.Bytes
                $item.ExportStatus = if ($copy.Success) { 'Success' } else { 'Failed' }
                if (-not $copy.Success) {
                    Write-MigrationLog -Message "AppData export failed for $folder ($($root.Label)), exit code $($copy.ExitCode)" -Level Error
                }
            } catch {
                $item.ExportStatus = 'Failed'
                Write-MigrationLog -Message "Exception exporting AppData $folder ($($root.Label)): $($_.Exception.Message)" -Level Error
            }

            $exportedItems.Add($item)
        }
    }

    $successCount = @($exportedItems | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "AppData export complete. $successCount of $($exportedItems.Count) items exported successfully." -Level Info

    return $exportedItems.ToArray()
}
