<#
========================================================================================================
    Title:          Win11Migrator - Pre-Import Rollback Snapshot
    Filename:       New-RollbackSnapshot.ps1
    Description:    Captures a snapshot of user data fingerprints and registry keys before import for rollback support.
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
    Snapshot the current system state before a migration import so it can be rolled back.
.DESCRIPTION
    Before the import phase begins, this function captures:
    1. File fingerprints (via Get-PackageFingerprint) for user data paths that will be overwritten.
    2. Registry key exports for HKCU paths that will be modified.
    All snapshot data is saved under the specified SnapshotPath directory along with metadata.
.PARAMETER SnapshotPath
    Directory where snapshot data will be stored.
.PARAMETER UserDataPaths
    User profile directories that will be overwritten during import.
.PARAMETER RegistryPaths
    HKCU registry paths that will be modified during import.
.OUTPUTS
    [hashtable] with SnapshotPath, DataPathCount, RegistryKeyCount, and Success.
#>

function New-RollbackSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,

        [Parameter()]
        [string[]]$UserDataPaths,

        [Parameter()]
        [string[]]$RegistryPaths
    )

    Write-MigrationLog -Message "Creating rollback snapshot at: $SnapshotPath" -Level Info

    $success = $true
    $dataPathCount = 0
    $registryKeyCount = 0
    $warnings = @()

    try {
        # Ensure snapshot directory exists
        if (-not (Test-Path $SnapshotPath)) {
            New-Item -Path $SnapshotPath -ItemType Directory -Force | Out-Null
        }

        # --- 1. Snapshot user data paths (fingerprints, not full copies) ---
        $dataSnapshotDir = Join-Path $SnapshotPath 'UserDataFingerprints'
        if ($UserDataPaths -and $UserDataPaths.Count -gt 0) {
            if (-not (Test-Path $dataSnapshotDir)) {
                New-Item -Path $dataSnapshotDir -ItemType Directory -Force | Out-Null
            }

            foreach ($dataPath in $UserDataPaths) {
                if (-not (Test-Path $dataPath)) {
                    Write-MigrationLog -Message "Snapshot: user data path does not exist, skipping: $dataPath" -Level Warning
                    $warnings += "Path not found: $dataPath"
                    continue
                }

                try {
                    # Generate a safe filename from the path
                    $safeName = ($dataPath -replace '[\\/:*?"<>|]', '_').TrimStart('_')
                    $fingerprintFile = Join-Path $dataSnapshotDir "$safeName.json"

                    $fingerprint = Get-PackageFingerprint -Path $dataPath -OutputFile $fingerprintFile -Algorithm None
                    $dataPathCount++
                    Write-MigrationLog -Message "Snapshot: fingerprinted $dataPath ($($fingerprint.TotalFiles) files)" -Level Debug
                }
                catch {
                    Write-MigrationLog -Message "Snapshot: failed to fingerprint ${dataPath}: $($_.Exception.Message)" -Level Warning
                    $warnings += "Failed to fingerprint: $dataPath"
                }
            }
        }

        # --- 2. Snapshot registry keys ---
        $regSnapshotDir = Join-Path $SnapshotPath 'RegistryBackups'
        if ($RegistryPaths -and $RegistryPaths.Count -gt 0) {
            if (-not (Test-Path $regSnapshotDir)) {
                New-Item -Path $regSnapshotDir -ItemType Directory -Force | Out-Null
            }

            foreach ($regPath in $RegistryPaths) {
                try {
                    # Convert PowerShell registry path to reg.exe format if needed
                    $regExePath = $regPath -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\'

                    # Generate safe filename
                    $safeName = ($regPath -replace '[\\/:*?"<>|]', '_').TrimStart('_')
                    $regFile = Join-Path $regSnapshotDir "$safeName.reg"

                    # Try reg export first (captures full key tree)
                    $regOutput = & reg export $regExePath $regFile /y 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $registryKeyCount++
                        Write-MigrationLog -Message "Snapshot: exported registry key $regPath" -Level Debug
                    }
                    else {
                        # Fallback: use PowerShell to read and save as JSON
                        if (Test-Path "Registry::$regExePath") {
                            $regData = Get-ItemProperty -Path "Registry::$regExePath" -ErrorAction Stop
                            $jsonFile = Join-Path $regSnapshotDir "$safeName.json"
                            $regData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8 -Force
                            $registryKeyCount++
                            Write-MigrationLog -Message "Snapshot: exported registry key $regPath (JSON fallback)" -Level Debug
                        }
                        else {
                            Write-MigrationLog -Message "Snapshot: registry key does not exist, skipping: $regPath" -Level Warning
                            $warnings += "Registry key not found: $regPath"
                        }
                    }
                }
                catch {
                    Write-MigrationLog -Message "Snapshot: failed to export registry key ${regPath}: $($_.Exception.Message)" -Level Warning
                    $warnings += "Failed to export registry: $regPath"
                }
            }
        }

        # --- 3. Save snapshot metadata ---
        $metadata = @{
            Timestamp        = (Get-Date).ToUniversalTime().ToString('o')
            ComputerName     = $env:COMPUTERNAME
            UserName         = $env:USERNAME
            UserDataPaths    = $UserDataPaths
            RegistryPaths    = $RegistryPaths
            DataPathCount    = $dataPathCount
            RegistryKeyCount = $registryKeyCount
            Warnings         = $warnings
        }

        $metadataPath = Join-Path $SnapshotPath 'snapshot-metadata.json'
        $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path $metadataPath -Encoding UTF8 -Force

        Write-MigrationLog -Message "Rollback snapshot created: $dataPathCount data paths, $registryKeyCount registry keys" -Level Success
    }
    catch {
        $success = $false
        Write-MigrationLog -Message "Rollback snapshot failed: $($_.Exception.Message)" -Level Error
    }

    return @{
        SnapshotPath     = $SnapshotPath
        DataPathCount    = $dataPathCount
        RegistryKeyCount = $registryKeyCount
        Success          = $success
    }
}
