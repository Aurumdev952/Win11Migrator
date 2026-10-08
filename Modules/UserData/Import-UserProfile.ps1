<#
========================================================================================================
    Title:          Win11Migrator - User Profile Data Importer
    Filename:       Import-UserProfile.ps1
    Description:    Restores user profile data from a migration package to the target machine via Robocopy.
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
    Restores user data folders from a migration package to the target machine.
.DESCRIPTION
    Reads UserDataItem objects from a manifest, locates the exported files in the
    migration package, and restores them to the current user's profile paths using
    Robocopy. Handles path differences between source and target machines.
.PARAMETER Items
    UserDataItem[] from the migration manifest.
.PARAMETER PackagePath
    Root path of the migration package containing the exported UserData folder.
.PARAMETER TargetProfilePaths
    Optional hashtable from Get-UserProfilePaths on the target machine. If not
    provided, the function will call Get-UserProfilePaths automatically.
.PARAMETER MoveFromPackage
    Rename package folders into place instead of copying them (same volume only).
.OUTPUTS
    [UserDataItem[]] The same items with ImportStatus set.
#>

function Get-UserDataRestoreTarget {
    <#
    .SYNOPSIS
        Where an exported folder belongs on this PC: the known folder for standard categories
        (which honours OneDrive redirection), otherwise %USERPROFILE%\<RelativePath>.
    #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$TargetProfilePaths)
    if ($Item.Category -and $Item.Category -ne 'Custom' -and $TargetProfilePaths.ContainsKey($Item.Category)) {
        return $TargetProfilePaths[$Item.Category]
    }
    $relative = if ($Item.RelativePath) { $Item.RelativePath } else { $Item.Category }
    return Join-Path $env:USERPROFILE $relative
}

function Import-UserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [hashtable]$TargetProfilePaths,

        [switch]$MoveFromPackage,

        [hashtable]$Progress,

        [switch]$PreserveACLs
    )

    Write-MigrationLog -Message "Beginning user profile import from $PackagePath" -Level Info

    if (-not $TargetProfilePaths) {
        $TargetProfilePaths = Get-UserProfilePaths
    }
    $dataRoot = Join-Path $PackagePath 'UserData'

    foreach ($item in $Items) {
        if ($item.Category -eq 'AppData') { continue }
        if (-not $item.Selected -or $item.ExportStatus -in 'Skipped', 'Failed') {
            $item.ImportStatus = 'Skipped'
            continue
        }

        $relative = if ($item.RelativePath) { $item.RelativePath } else { $item.Category }
        $packageSourcePath = Join-Path $dataRoot $relative
        if ($Progress) { $Progress['Item'] = $relative }

        if (-not (Test-Path -LiteralPath $packageSourcePath)) {
            $item.ImportStatus = 'Failed'
            Write-MigrationLog -Message "Package source not found: $packageSourcePath" -Level Warning
            continue
        }

        $targetPath = Get-UserDataRestoreTarget -Item $item -TargetProfilePaths $TargetProfilePaths

        try {
            if (Test-Path -LiteralPath $packageSourcePath -PathType Container) {
                $restore = Restore-PackageFolder -Source $packageSourcePath -Destination $targetPath -Move:$MoveFromPackage `
                    -CopySecurity:$PreserveACLs -Progress $Progress -SizeHint ([long]$item.SizeBytes)
                $item.ImportStatus = if ($restore.Success) { 'Success' } else { 'Failed' }
                if (-not $restore.Success) {
                    Write-MigrationLog -Message "Restore failed for $relative (robocopy exit code $($restore.ExitCode))" -Level Error
                } elseif ($PreserveACLs) {
                    $aclFile = Join-Path (Join-Path $dataRoot 'ACLs') "$relative.json"
                    if (Test-Path -LiteralPath $aclFile) {
                        try {
                            Import-FileACLs -ACLPath $aclFile -TargetBasePath $targetPath
                        } catch {
                            Write-MigrationLog -Message "ACL restore failed for $($relative): $($_.Exception.Message)" -Level Warning
                        }
                    }
                }
            } else {
                New-Item -Path (Split-Path $targetPath -Parent) -ItemType Directory -Force | Out-Null
                Copy-Item -LiteralPath $packageSourcePath -Destination $targetPath -Force -ErrorAction Stop
                $item.ImportStatus = 'Success'
            }
            Write-MigrationLog -Message "Restored $relative -> $targetPath ($($item.ImportStatus))" -Level Info
        } catch {
            $item.ImportStatus = 'Failed'
            Write-MigrationLog -Message "Failed to import $($relative): $($_.Exception.Message)" -Level Error
        }
    }

    $restored = @($Items | Where-Object { $_.Category -ne 'AppData' })
    $successCount = @($restored | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    $failCount    = @($restored | Where-Object { $_.ImportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "User profile import complete. Success: $successCount, Failed: $failCount" -Level Info

    return $Items
}
