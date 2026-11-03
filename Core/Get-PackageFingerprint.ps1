<#
========================================================================================================
    Title:          Win11Migrator - Package Fingerprint Generator
    Filename:       Get-PackageFingerprint.ps1
    Description:    Recursively scans a directory and computes SHA256 hashes for incremental backup support.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Generate a file-level fingerprint of a directory for incremental change detection.
.DESCRIPTION
    Recursively enumerates all files under the given path, computing a SHA256 hash for each.
    The resulting fingerprint can be saved as JSON and later compared via Compare-PackageFingerprint
    to identify added, modified, deleted, and unchanged files.
.PARAMETER Path
    Directory to fingerprint.
.PARAMETER OutputFile
    Optional path to save the fingerprint as a JSON file.
.OUTPUTS
    [hashtable] with Path, Files, TotalFiles, TotalSizeBytes, and GeneratedAt.
#>

function Get-PackageFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [string]$OutputFile,

        # None records path, size and timestamp only: enough to tell which files are new or changed,
        # without reading every byte.
        [ValidateSet('SHA256', 'None')]
        [string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path $Path)) {
        Write-MigrationLog -Message "Fingerprint path does not exist: $Path" -Level Error
        throw "Directory not found: $Path"
    }

    $resolvedPath = (Resolve-Path $Path).Path
    Write-MigrationLog -Message "Generating fingerprint for: $resolvedPath" -Level Info

    $files = [System.Collections.Generic.List[hashtable]]::new()
    $totalSize = [long]0
    $fileCount = 0
    $errorCount = 0

    # Enumerate all files recursively
    $allFiles = @()
    try {
        $allFiles = @(Get-ChildItem -Path $resolvedPath -Recurse -File -ErrorAction SilentlyContinue)
    }
    catch {
        Write-MigrationLog -Message "Error enumerating files in ${resolvedPath}: $($_.Exception.Message)" -Level Warning
    }

    foreach ($file in $allFiles) {
        $fileCount++

        # Log progress every 100 files
        if ($fileCount % 100 -eq 0) {
            Write-MigrationLog -Message "Fingerprint progress: $fileCount files processed" -Level Debug
        }

        try {
            # Compute relative path from the root
            $relativePath = $file.FullName.Substring($resolvedPath.Length).TrimStart('\', '/')

            $hash = if ($Algorithm -eq 'SHA256') {
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } else {
                "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
            }

            $files.Add(@{
                RelativePath     = $relativePath
                Hash             = $hash
                SizeBytes        = $file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
            })

            $totalSize += $file.Length
        }
        catch {
            $errorCount++
            Write-MigrationLog -Message "Access denied or error hashing file: $($file.FullName) - $($_.Exception.Message)" -Level Debug
        }
    }

    if ($errorCount -gt 0) {
        Write-MigrationLog -Message "Fingerprint completed with $errorCount inaccessible files skipped" -Level Warning
    }

    $fingerprint = @{
        Path           = $resolvedPath
        Files          = $files.ToArray()
        TotalFiles     = $files.Count
        TotalSizeBytes = $totalSize
        GeneratedAt    = (Get-Date).ToUniversalTime().ToString('o')
    }

    Write-MigrationLog -Message "Fingerprint generated: $($files.Count) files, $([math]::Round($totalSize / 1MB, 2)) MB" -Level Info

    # Save to JSON if OutputFile specified
    if ($OutputFile) {
        try {
            $outputDir = Split-Path $OutputFile -Parent
            if ($outputDir -and -not (Test-Path $outputDir)) {
                New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
            }
            $fingerprint | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8 -Force
            Write-MigrationLog -Message "Fingerprint saved to: $OutputFile" -Level Info
        }
        catch {
            Write-MigrationLog -Message "Failed to save fingerprint to ${OutputFile}: $($_.Exception.Message)" -Level Error
        }
    }

    return $fingerprint
}
