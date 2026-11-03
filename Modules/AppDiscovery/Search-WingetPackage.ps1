<#
========================================================================================================
    Title:          Win11Migrator - Winget Package Search
    Filename:       Search-WingetPackage.ps1
    Description:    Searches the winget repository for a matching package ID for a given application.
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
    Searches the winget repository for a package matching a given application name.
    Returns the best match with its package ID and a confidence score.
#>

function Search-WingetPackageUncached {
    <#
    .SYNOPSIS
        Searches winget for a matching package using the normalized application name.
    .PARAMETER AppName
        The application name to search for.
    .PARAMETER NormalizedName
        Pre-normalized app name. If not provided, the AppName will be normalized.
    .OUTPUTS
        [PSCustomObject] with properties: Found, PackageId, PackageName, Confidence, Source
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$AppName,

        [Parameter()]
        [string]$NormalizedName
    )

    $emptyResult = [PSCustomObject]@{
        Found      = $false
        PackageId  = ''
        PackageName = ''
        Confidence = 0.0
        Source     = 'Winget'
    }

    # Verify winget is available
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-MigrationLog -Message "Search-WingetPackage: winget not available" -Level Debug
        return $emptyResult
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        $NormalizedName = Get-NormalizedAppName -Name $AppName
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        return $emptyResult
    }

    Write-MigrationLog -Message "Searching winget for: $NormalizedName" -Level Debug

    # --- Phase 0: Static ID map lookup (instant, no CLI call) ---
    if (-not $script:CachedWingetIdMap) {
        $mapPath = Join-Path $script:MigratorRoot "Config\WingetIdMap.json"
        if (Test-Path $mapPath) {
            try {
                $mapRaw = Get-Content $mapPath -Raw | ConvertFrom-Json
                $script:CachedWingetIdMap = @{}
                $mapRaw.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
                    $script:CachedWingetIdMap[$_.Name] = $_.Value
                }
                Write-MigrationLog -Message "Loaded WingetIdMap with $($script:CachedWingetIdMap.Count) entries" -Level Debug
            } catch {
                $script:CachedWingetIdMap = @{}
            }
        } else {
            $script:CachedWingetIdMap = @{}
        }
    }

    # Check static map with original name (lowercase) and normalized name
    $lookupKeys = @($NormalizedName, $AppName.ToLower().Trim()) | Select-Object -Unique
    foreach ($key in $lookupKeys) {
        if ($script:CachedWingetIdMap.ContainsKey($key)) {
            $mappedId = $script:CachedWingetIdMap[$key]
            Write-MigrationLog -Message "Winget: static map match '$key' -> '$mappedId'" -Level Debug
            return [PSCustomObject]@{
                Found       = $true
                PackageId   = $mappedId
                PackageName = $AppName
                Confidence  = 0.95
                Source      = 'Winget'
            }
        }
    }

    # --- Phase 1: Dynamic winget search (fallback for unknown apps) ---
    # Execute winget search
    try {
        $rawOutput = & winget search $NormalizedName --accept-source-agreements --disable-interactivity 2>&1
        $outputLines = $rawOutput | Out-String -Stream | Where-Object { $_ -is [string] }
    }
    catch {
        Write-MigrationLog -Message "winget search failed: $($_.Exception.Message)" -Level Warning
        return $emptyResult
    }

    if (-not $outputLines -or $outputLines.Count -eq 0) {
        return $emptyResult
    }

    # Check if winget returned "No package found"
    $noResultLine = $outputLines | Where-Object { $_ -match 'No package found' }
    if ($noResultLine) {
        return $emptyResult
    }

    # Parse the table output - find header separator
    $separatorIndex = -1
    $headerLineIndex = -1
    for ($i = 0; $i -lt $outputLines.Count; $i++) {
        if ($outputLines[$i] -match '^-{3,}') {
            $separatorIndex = $i
            $headerLineIndex = $i - 1
            break
        }
    }

    if ($separatorIndex -lt 0 -or $headerLineIndex -lt 0) {
        return $emptyResult
    }

    # Determine column positions from the header
    $headerLine = $outputLines[$headerLineIndex]
    $nameStart    = 0
    $idStart      = $headerLine.IndexOf('Id')
    $versionStart = $headerLine.IndexOf('Version')
    $sourceStart  = $headerLine.IndexOf('Source')

    if ($idStart -lt 0) {
        return $emptyResult
    }

    # Parse result rows
    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

    for ($i = $separatorIndex + 1; $i -lt $outputLines.Count; $i++) {
        $line = $outputLines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\d+ (packages|results)') { continue }
        if ($line.Length -lt $idStart + 2) { continue }

        $pkgName = ''
        $pkgId   = ''

        try {
            $pkgName = $line.Substring($nameStart, [Math]::Min($idStart, $line.Length)).TrimEnd()
            if ($versionStart -gt $idStart -and $line.Length -gt $idStart) {
                $idLen = $versionStart - $idStart
                $pkgId = $line.Substring($idStart, [Math]::Min($idLen, $line.Length - $idStart)).TrimEnd()
            }
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($pkgName) -or [string]::IsNullOrWhiteSpace($pkgId)) {
            continue
        }

        $normalizedCandidate = Get-NormalizedAppName -Name $pkgName
        $similarity = Get-AppNameSimilarity -Name1 $NormalizedName -Name2 $normalizedCandidate

        $candidates.Add([PSCustomObject]@{
            PackageName = $pkgName.Trim()
            PackageId   = $pkgId.Trim()
            Similarity  = $similarity
        })
    }

    if ($candidates.Count -eq 0) {
        return $emptyResult
    }

    # Sort by similarity descending and pick the best match
    $best = $candidates | Sort-Object -Property Similarity -Descending | Select-Object -First 1

    # Require minimum confidence threshold of 0.5
    if ($best.Similarity -lt 0.5) {
        Write-MigrationLog -Message "Winget: best match for '$NormalizedName' was '$($best.PackageName)' with confidence $([Math]::Round($best.Similarity, 2)) - below threshold" -Level Debug
        return $emptyResult
    }

    Write-MigrationLog -Message "Winget: matched '$NormalizedName' -> '$($best.PackageId)' (confidence: $([Math]::Round($best.Similarity, 2)))" -Level Debug

    return [PSCustomObject]@{
        Found       = $true
        PackageId   = $best.PackageId
        PackageName = $best.PackageName
        Confidence  = $best.Similarity
        Source      = 'Winget'
    }
}

function Search-WingetPackage {
    <#
    .SYNOPSIS
        Search-WingetPackageUncached with results cached per normalized name; several installed
        entries often normalize to the same product, and each `winget search` costs seconds.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [string]$NormalizedName
    )
    if (-not $script:WingetSearchCache) { $script:WingetSearchCache = @{} }
    $key = if ($NormalizedName) { $NormalizedName } else { Get-NormalizedAppName -Name $AppName }
    if (-not $key) { return Search-WingetPackageUncached -AppName $AppName -NormalizedName $NormalizedName }
    if (-not $script:WingetSearchCache.ContainsKey($key)) {
        $script:WingetSearchCache[$key] = Search-WingetPackageUncached -AppName $AppName -NormalizedName $key
    }
    return $script:WingetSearchCache[$key]
}
