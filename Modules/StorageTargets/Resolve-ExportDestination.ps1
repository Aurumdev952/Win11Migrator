<#
========================================================================================================
    Title:          Win11Migrator - Export Destination Resolver
    Filename:       Resolve-ExportDestination.ps1
    Description:    Maps the chosen storage target to the folder the package is written into, and
                    refuses to start when that destination cannot hold the selected data.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

$script:DestinationKinds = @{
    USB          = @{ TargetKind = 'USB';     CopyMigrator = $true }
    Custom       = @{ TargetKind = 'Local';   CopyMigrator = $true }
    OneDrive     = @{ TargetKind = 'Cloud';   CopyMigrator = $true }
    GoogleDrive  = @{ TargetKind = 'Cloud';   CopyMigrator = $true }
    NetworkShare = @{ TargetKind = 'Network'; CopyMigrator = $true }
    LanReceive   = @{ TargetKind = 'Network'; CopyMigrator = $false }
    AdminShare   = @{ TargetKind = 'Network'; CopyMigrator = $true }
    Local        = @{ TargetKind = 'Local';   CopyMigrator = $false }
}

function Get-PathFreeSpace {
    <#
    .SYNOPSIS
        Free bytes available at a local or UNC path, or $null when it cannot be determined.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $probe = $Path
    while ($probe -and -not (Test-Path -LiteralPath $probe)) { $probe = Split-Path $probe -Parent }
    if (-not $probe) { return $null }

    if (Test-UncPath $probe) {
        if (-not ('Win11Migrator.DiskSpace' -as [type])) {
            Add-Type -Namespace Win11Migrator -Name DiskSpace -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);
'@
        }
        $free = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
        if ([Win11Migrator.DiskSpace]::GetDiskFreeSpaceEx($probe, [ref]$free, [ref]$total, [ref]$totalFree)) { return [long]$free }
        return $null
    }

    try {
        return [long]([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $probe).ProviderPath))).AvailableFreeSpace
    } catch {
        return $null
    }
}

function Resolve-ExportDestination {
    <#
    .SYNOPSIS
        Resolves where the package is written.
    .PARAMETER StorageTarget
        @{ Type = 'USB'|'Custom'|'OneDrive'|'GoogleDrive'|'NetworkShare'|'LanReceive'|'AdminShare'; Path = ... }
        or $null for a local export.
    .PARAMETER RequiredBytes
        Bytes the selected data needs. A destination with less free space throws before anything is copied.
    .OUTPUTS
        PSCustomObject with Type, Root, TargetKind, CopyMigrator and FreeBytes.
    #>
    [CmdletBinding()]
    param(
        $StorageTarget,
        [long]$RequiredBytes = 0,
        [string]$LocalPackageRoot = $script:Config.PackagePath
    )

    $type = if ($StorageTarget -and $StorageTarget.Type) { [string]$StorageTarget.Type } else { 'Local' }
    if (-not $script:DestinationKinds.ContainsKey($type)) { throw "Unknown storage target type '$type'" }
    $path = if ($StorageTarget) { [string]$StorageTarget.Path } else { '' }

    # Path.Combine, not Join-Path: Join-Path fails on a drive letter PowerShell has not mounted yet
    $root = switch ($type) {
        'USB'        { [System.IO.Path]::Combine("$($path.Trim().Substring(0, 1)):\", 'Win11Migrator') }
        'LanReceive' { $path }
        'Local'      { $LocalPackageRoot }
        default      { if ($path) { [System.IO.Path]::Combine($path, 'Win11Migrator') } }
    }
    if ([string]::IsNullOrWhiteSpace($root)) { throw "No destination path was chosen for $type" }

    $free = Get-PathFreeSpace -Path $root
    $bufferBytes = [long](Get-MigrationSetting $script:Config 'DiskSpaceBufferMB' 500) * 1MB
    if ($null -ne $free -and $RequiredBytes -gt 0 -and $free -lt ($RequiredBytes + $bufferBytes)) {
        throw ("Not enough space at {0}: {1:N1} GB free, {2:N1} GB needed. Free up space, pick a larger drive, or deselect folders." -f `
            $root, ($free / 1GB), (($RequiredBytes + $bufferBytes) / 1GB))
    }

    $kind = $script:DestinationKinds[$type]
    return [PSCustomObject]@{
        Type         = $type
        Root         = $root
        TargetKind   = $kind.TargetKind
        CopyMigrator = $kind.CopyMigrator
        FreeBytes    = $free
    }
}
