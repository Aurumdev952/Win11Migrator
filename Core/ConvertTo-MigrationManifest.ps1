<#
========================================================================================================
    Title:          Win11Migrator - Migration Manifest Converter
    Filename:       ConvertTo-MigrationManifest.ps1
    Description:    Serializes scan results into a MigrationManifest JSON file for the migration package.
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
    Serialize scan results into a manifest.json file for the migration package.
#>

function ConvertTo-MigrationManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        $Apps,
        $UserData,
        $BrowserProfiles,
        $SystemSettings,
        $AppProfiles,
        [hashtable]$Metadata
    )

    $manifest = [MigrationManifest]::new()
    $manifest.ExportDate = (Get-Date).ToString('o')
    $manifest.SourceComputerName = $env:COMPUTERNAME
    $manifest.SourceOSVersion = [System.Environment]::OSVersion.VersionString
    $manifest.SourceUserName = $env:USERNAME

    # Capture OS context for cross-OS migration support
    try {
        $ntReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($ntReg) {
            $manifest.SourceOSBuild = $ntReg.CurrentBuildNumber
            $buildNum = [int]$ntReg.CurrentBuildNumber
            $manifest.SourceOSContext = @{
                IsWindows10 = ($buildNum -ge 10240 -and $buildNum -lt 22000)
                IsWindows11 = ($buildNum -ge 22000)
                BuildNumber = $buildNum
                DisplayVersion = if ($ntReg.DisplayVersion) { $ntReg.DisplayVersion } else { '' }
            }
            if ($manifest.SourceOSContext.IsWindows10) {
                $manifest.MigrationScope = 'Win10'
            } elseif ($manifest.SourceOSContext.IsWindows11) {
                $manifest.MigrationScope = 'Win11'
            }
        }
    } catch {}

    # USMT store presence
    if ($Metadata -and $Metadata.ContainsKey('USMTStorePresent')) {
        $manifest.USMTStorePresent = $Metadata['USMTStorePresent']
    }

    # Assign data arrays — use @() wrapping to safely handle cross-runspace type differences
    if ($Apps)            { $manifest.Apps = @($Apps) }
    if ($UserData)        { $manifest.UserData = @($UserData) }
    if ($BrowserProfiles) { $manifest.BrowserProfiles = @($BrowserProfiles) }
    if ($SystemSettings)  { $manifest.SystemSettings = @($SystemSettings) }
    if ($AppProfiles)     { $manifest.AppProfiles = @($AppProfiles) }
    if ($Metadata)        { $manifest.Metadata = $Metadata }

    $json = $manifest | ConvertTo-Json -Depth 10
    $manifestFile = Join-Path $OutputPath "manifest.json"
    # Temp file then rename: a receiving PC polls for this file and must never read half of it
    $tempFile = "$manifestFile.tmp"
    Set-Content -Path $tempFile -Value $json -Encoding UTF8
    Move-Item -Path $tempFile -Destination $manifestFile -Force

    Write-MigrationLog -Message "Manifest written to $manifestFile" -Level Success
    return $manifestFile
}
