<#
========================================================================================================
    Title:          Win11Migrator - User Profile Data Exporter
    Filename:       Export-UserProfile.ps1
    Description:    Exports user profile data (Desktop, Documents, Downloads, etc.) via Robocopy to the migration package.
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
    Exports selected user data folders through the shared Robocopy wrapper.
.DESCRIPTION
    Each selected item is copied with Invoke-Robocopy (junctions skipped, exclusions applied,
    live byte progress). Each item's ExportStatus is updated, and SizeBytes is filled from
    the bytes actually copied when the scan did not measure it.
.PARAMETER Items
    UserDataItem[] of folders/files to export.
.PARAMETER OutputDirectory
    The package's UserData directory; each item lands in OutputDirectory\<RelativePath>.
.PARAMETER Exclusions
    Hashtable with Directories and Files, from Get-MigrationExclusions.
.OUTPUTS
    [UserDataItem[]] Updated items with ExportStatus set.
#>

function Export-UserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [UserDataItem[]]$Items,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [hashtable]$Exclusions = (Get-MigrationExclusions),

        [ValidateSet('Local', 'USB', 'Network', 'Cloud')]
        [string]$TargetKind = 'Local',

        [hashtable]$Progress,

        [scriptblock]$OnProgress,

        [switch]$PreserveACLs
    )

    Write-MigrationLog -Message "Beginning user profile export to $OutputDirectory" -Level Info

    $selectedItems = @($Items | Where-Object { $_.Selected })
    $totalCount = $selectedItems.Count
    $currentIndex = 0

    foreach ($item in $Items) {
        if (-not $item.Selected) {
            $item.ExportStatus = 'Skipped'
            continue
        }

        $currentIndex++
        if ($Progress) { $Progress['Item'] = "$($item.RelativePath) ($currentIndex of $totalCount)" }
        Write-MigrationLog -Message "Exporting [$currentIndex/$totalCount]: $($item.Category) - $($item.SourcePath)" -Level Info

        if (-not (Test-Path -LiteralPath $item.SourcePath)) {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Source path does not exist: $($item.SourcePath)" -Level Warning
            continue
        }

        $relative = if ($item.RelativePath) { $item.RelativePath } else { $item.Category }
        $destPath = Join-Path $OutputDirectory $relative

        try {
            $sourceItem = Get-Item -LiteralPath $item.SourcePath -Force -ErrorAction Stop
            if ($sourceItem.PSIsContainer) {
                $copy = Invoke-Robocopy -Source $item.SourcePath -Destination $destPath -TargetKind $TargetKind `
                    -Exclusions $Exclusions -CopySecurity:$PreserveACLs -Progress $Progress -OnProgress $OnProgress
                if (-not $item.SizeBytes) { $item.SizeBytes = $copy.Bytes }
                if ($copy.Success) {
                    $item.ExportStatus = 'Success'
                    if ($copy.Failed -gt 0) {
                        Write-MigrationLog -Message "$($item.Category): $($copy.Failed) file(s) could not be copied (locked or access denied)" -Level Warning
                    }
                    if ($PreserveACLs) {
                        try {
                            Export-FileACLs -SourcePath $item.SourcePath -OutputPath (Join-Path (Join-Path $OutputDirectory 'ACLs') "$relative.json")
                        } catch {
                            Write-MigrationLog -Message "ACL export failed for $($item.Category): $($_.Exception.Message)" -Level Warning
                        }
                    }
                } else {
                    $item.ExportStatus = 'Failed'
                    Write-MigrationLog -Message "Robocopy failed for $($item.SourcePath) with exit code $($copy.ExitCode): $(($copy.Tail | Select-Object -Last 5) -join '; ')" -Level Error
                }
            } else {
                $destDir = Split-Path $destPath -Parent
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                Copy-Item -LiteralPath $item.SourcePath -Destination $destPath -Force -ErrorAction Stop
                if ($Progress) { $Progress['BytesDone'] = [long]$Progress['BytesDone'] + $sourceItem.Length }
                $item.ExportStatus = 'Success'
            }
        } catch {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Failed to export $($item.SourcePath): $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = @($Items | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    $failCount    = @($Items | Where-Object { $_.ExportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "User profile export complete. Success: $successCount, Failed: $failCount" -Level Info

    return $Items
}
