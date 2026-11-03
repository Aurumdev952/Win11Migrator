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
                    -Exclusions (Get-ItemExclusions -Exclusions $Exclusions -Item $item) -CopySecurity:$PreserveACLs -Progress $Progress -OnProgress $OnProgress
                Write-MigrationLog -Message "$($relative): robocopy $($copy.Arguments)" -Level Info
                Write-MigrationLog -Message "$($relative): robocopy exit code $($copy.ExitCode), saw $($copy.Seen) file(s), copied $($copy.Files) file(s) and $($copy.Bytes) bytes, $($copy.Failed) failed" -Level Info
                # A folder measured with data where robocopy saw no files at all was not really copied
                $sawNothing = ($item.SizeBytes -gt 0 -and $copy.Seen -eq 0 -and $copy.Files -eq 0)
                if ($sawNothing) {
                    foreach ($line in @($copy.Tail | Where-Object { $_.Trim() } | Select-Object -Last 15)) {
                        Write-MigrationLog -Message "$($relative): robocopy said: $line" -Level Warning
                    }
                }
                if (-not $item.SizeBytes) { $item.SizeBytes = $copy.Bytes }
                # Exit codes 8-15 with a count of failed files mean only those files were missed. Without
                # that count robocopy failed on the folder itself (access denied, path not found).
                if (-not $sawNothing -and ($copy.ExitCode -lt 8 -or ($copy.ExitCode -lt 16 -and $copy.Failed -gt 0))) {
                    $item.ExportStatus = 'Success'
                    if ($copy.Failed -gt 0) {
                        $item.FailedFiles = [int]$copy.Failed
                        Write-MigrationLog -Message "$($item.Category): $($copy.Failed) file(s) could not be copied (locked or access denied)" -Level Warning
                    }
                    if ($PreserveACLs) {
                        try {
                            Export-FileACLs -SourcePath $item.SourcePath -OutputFile (Join-Path (Join-Path $OutputDirectory 'ACLs') "$relative.json")
                        } catch {
                            Write-MigrationLog -Message "ACL export failed for $($item.Category): $($_.Exception.Message)" -Level Warning
                        }
                    }
                } else {
                    $item.ExportStatus = 'Failed'
                    $reason = @($copy.Tail | Where-Object { $_ -match 'ERROR|\(0x[0-9A-Fa-f]{8}\)' } | ForEach-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
                    $item.ExportError = if ($sawNothing) {
                        "robocopy found no files to copy although the folder measured $([Math]::Round($item.SizeBytes / 1GB, 2)) GB (exit code $($copy.ExitCode)). See the log for robocopy's output."
                    } elseif ($reason) { "robocopy exit code $($copy.ExitCode): $reason" } else { "robocopy exit code $($copy.ExitCode): $((@($copy.Tail) | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / ')" }
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
