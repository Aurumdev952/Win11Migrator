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
    # Returns the destination paths that were moved.
    param([string]$Source, [string]$Destination)
    $moved = [System.Collections.Generic.List[string]]::new()
    foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
        $target = Join-Path $Destination $child.Name
        if (-not (Test-Path -LiteralPath $target)) {
            try {
                Move-Item -LiteralPath $child.FullName -Destination $target -ErrorAction Stop
                $moved.Add($target)
            } catch {
                Write-MigrationLog -Message "Could not move $($child.FullName); it will be copied instead: $($_.Exception.Message)" -Level Debug
            }
        } elseif ($child.PSIsContainer -and (Test-Path -LiteralPath $target -PathType Container)) {
            foreach ($m in (Move-PackageTree -Source $child.FullName -Destination $target)) { $moved.Add($m) }
            if (-not (Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return , $moved.ToArray()
}

function Reset-InheritedAcl {
    # A rename keeps the ACL from where the file was received (the incoming folder grants wide access);
    # a copy would have inherited the profile's. Make moved entries inherit from their new parent.
    param([string[]]$Paths)
    if (-not $Paths -or -not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) { return }
    $ErrorActionPreference = 'Continue'
    foreach ($p in $Paths) {
        & icacls.exe $p /reset /T /C /Q 2>&1 | Out-Null
    }
}

function Restore-PackageFolder {
    <#
    .SYNOPSIS
        Restores a package folder into Destination, merging with what is already there.
    .PARAMETER Move
        Consume the package: entries are renamed into place when Source and Destination share a volume,
        then given the destination's inherited permissions. Used for packages received over the network.
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
        Reset-InheritedAcl -Paths (Move-PackageTree -Source $Source -Destination $Destination)
        $leftover = Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $leftover) {
            if ($Progress) { $Progress['BytesDone'] = [long]$Progress['BytesDone'] + $SizeHint }
            return [PSCustomObject]@{ Success = $true; Moved = $true; ExitCode = 0 }
        }
    }

    $copy = Invoke-Robocopy -Source $Source -Destination $Destination -CopySecurity:$CopySecurity -Progress $Progress
    return [PSCustomObject]@{ Success = $copy.Success; Moved = $false; ExitCode = $copy.ExitCode }
}
