<#
========================================================================================================
    Title:          Win11Migrator - Package Folder Restore
    Filename:       Restore-PackageFolder.ps1
    Description:    Puts one package folder in place on the target PC, by renaming when the package sits on
                    the same volume as the profile, or by copying through the shared Robocopy wrapper.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Test-SameVolume {
    param([string]$PathA, [string]$PathB)
    try {
        $rootA = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($PathA))
        $rootB = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($PathB))
        return ($rootA -and [string]::Equals($rootA, $rootB, [System.StringComparison]::OrdinalIgnoreCase))
    } catch {
        return $false
    }
}

function Move-PackageTree {
    # Moves every entry whose destination does not exist yet (a rename on one volume) and recurses
    # into folders that exist on both sides. Anything left behind is a real conflict for robocopy.
    param([string]$Source, [string]$Destination)
    foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
        $target = Join-Path $Destination $child.Name
        if (-not (Test-Path -LiteralPath $target)) {
            try { Move-Item -LiteralPath $child.FullName -Destination $target -ErrorAction Stop } catch { }
        } elseif ($child.PSIsContainer -and (Test-Path -LiteralPath $target -PathType Container)) {
            Move-PackageTree -Source $child.FullName -Destination $target
            if (-not (Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Restore-PackageFolder {
    <#
    .SYNOPSIS
        Restores a package folder into Destination, merging with what is already there.
    .PARAMETER Move
        Consume the package: entries are renamed into place when Source and Destination share a volume.
        Used for packages received over the network, which are deleted after import anyway.
    .PARAMETER SizeHint
        Bytes this folder holds; credited to Progress.BytesDone when the move needs no copy.
    .OUTPUTS
        PSCustomObject with Success, Moved and ExitCode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Move,
        [switch]$CopySecurity,
        [hashtable]$Progress,
        [long]$SizeHint = 0
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    if ($Move -and (Test-SameVolume $Source $Destination)) {
        Move-PackageTree -Source $Source -Destination $Destination
        $leftover = Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $leftover) {
            if ($Progress) { $Progress['BytesDone'] = [long]$Progress['BytesDone'] + $SizeHint }
            return [PSCustomObject]@{ Success = $true; Moved = $true; ExitCode = 0 }
        }
    }

    $copy = Invoke-Robocopy -Source $Source -Destination $Destination -CopySecurity:$CopySecurity -Progress $Progress
    return [PSCustomObject]@{ Success = $copy.Success; Moved = $false; ExitCode = $copy.ExitCode }
}
