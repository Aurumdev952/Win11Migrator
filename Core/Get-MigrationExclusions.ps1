<#
========================================================================================================
    Title:          Win11Migrator - Exclusion Lists
    Filename:       Get-MigrationExclusions.ps1
    Description:    Resolves the folder and file-pattern exclusions applied to every user data copy.
    Company:        AuthorityGate Inc.
    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Merge-PatternList {
    param([object[]]$Lists)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($list in $Lists) {
        foreach ($item in @($list)) {
            if ($null -eq $item) { continue }
            $value = ([string]$item).Trim().TrimEnd('\', '/')
            if ($value -and $seen.Add($value)) { $merged.Add($value) }
        }
    }
    return , $merged.ToArray()
}

function Get-MigrationExclusions {
    <#
    .SYNOPSIS
        Merges config defaults, the migration profile's Exclusions, and user additions.
    .OUTPUTS
        Hashtable with Directories and Files string arrays (case-insensitive, de-duplicated).
    #>
    [CmdletBinding()]
    param(
        $Config = $script:Config,
        $MigrationProfile = $script:MigrationProfile,
        [string[]]$ExtraDirectories,
        [string[]]$ExtraFiles
    )

    $profileExclusions = if ($MigrationProfile -and $MigrationProfile.PSObject.Properties['Exclusions']) { $MigrationProfile.Exclusions } else { $null }

    return @{
        Directories = Merge-PatternList @(
            (Get-MigrationSetting $Config 'ExcludeDirectories' @()),
            $(if ($profileExclusions) { $profileExclusions.Directories }),
            $ExtraDirectories)
        Files = Merge-PatternList @(
            (Get-MigrationSetting $Config 'ExcludeFilePatterns' @()),
            $(if ($profileExclusions) { $profileExclusions.Files }),
            $ExtraFiles)
    }
}

function Test-PathExcluded {
    <#
    .SYNOPSIS
        True when a path relative to the copy root matches a directory or file exclusion,
        using the same name-based matching Robocopy applies to /XD and /XF.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][hashtable]$Exclusions
    )

    $segments = @($RelativePath -split '[\\/]' | Where-Object { $_ })
    if ($segments.Count -eq 0) { return $false }

    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        foreach ($pattern in $Exclusions.Directories) {
            if ($segments[$i] -like $pattern) { return $true }
        }
    }
    foreach ($pattern in $Exclusions.Files) {
        if ($segments[-1] -like $pattern) { return $true }
    }
    return $false
}
