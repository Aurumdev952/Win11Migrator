<#
========================================================================================================
    Title:          Win11Migrator - Environment Initialization & Class Definitions
    Filename:       Initialize-Environment.ps1
    Description:    Bootstraps the migration environment with class definitions, prerequisite checks, and config loading.
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
    Bootstrap the Win11Migrator environment: class definitions, prerequisite checks, config loading.
#>

# --- Class Definitions ---

class MigrationApp {
    [string]$Name
    [string]$NormalizedName
    [string]$Version
    [string]$Publisher
    [string]$InstallLocation
    [string]$UninstallString
    [string]$Source               # Registry, Winget, Store, ProgramFiles
    [string]$InstallMethod        # Winget, Chocolatey, Ninite, Store, VendorDownload, Manual
    [string]$PackageId            # winget/choco/store ID
    [string]$DownloadUrl
    [double]$MatchConfidence      # 0.0 - 1.0
    [bool]$Selected = $true
    [string]$InstallStatus        # Pending, Success, Failed, Skipped
    [string]$InstallError
}

class UserDataItem {
    [string]$SourcePath
    [string]$RelativePath
    [string]$Category            # Desktop, Documents, Downloads, Pictures, Videos, Music, AppData, Custom
    [long]$SizeBytes
    [bool]$Selected = $true
    [bool]$IsCustom = $false
    [bool]$IsCloudSynced = $false
    [string]$CloudProvider       # OneDrive, GoogleDrive, or empty
    [bool]$SkipCloudSync = $false  # True = user chose to let cloud re-sync instead of copying
    [string[]]$ExcludedDirs = @()  # Full paths the user unticked inside this folder
    [string[]]$ExcludedFiles = @()
    [int]$FailedFiles = 0          # Files robocopy could not copy (locked, in use, access denied)
    [string]$ExportError = ''      # Robocopy's own error lines when the folder could not be copied
    [string]$ExportStatus        # Pending, Success, Failed, Skipped
    [string]$ImportStatus        # Pending, Success, Failed, Skipped
}

class BrowserProfile {
    [string]$Browser             # Chrome, Edge, Firefox, Brave
    [string]$ProfileName
    [string]$ProfilePath
    [bool]$HasBookmarks
    [bool]$HasExtensions
    [bool]$HasHistory
    [bool]$HasPasswords          # Note: passwords are not exported for security
    [string[]]$Extensions
    [bool]$Selected = $true
    [string]$ExportStatus
    [string]$ImportStatus        # Pending, Success, Failed, Skipped
}

class SystemSetting {
    [string]$Category            # WiFi, Printer, MappedDrive, EnvVar, WindowsSetting
    [string]$Name
    [hashtable]$Data
    [bool]$Selected = $true
    [string]$ExportStatus
    [string]$ImportStatus
}

class MigrationManifest {
    [string]$Version = "1.0.0"
    [string]$ExportDate
    [string]$SourceComputerName
    [string]$SourceOSVersion
    [string]$SourceUserName
    [string]$SourceOSBuild
    [hashtable]$SourceOSContext
    [string]$MigrationScope           # SameOS, Win10ToWin11, Win11ToWin10
    [bool]$USMTStorePresent = $false
    [object[]]$Apps = @()
    [object[]]$UserData = @()
    [object[]]$BrowserProfiles = @()
    [object[]]$SystemSettings = @()
    [object[]]$AppProfiles = @()
    [hashtable]$Metadata = @{}
}

class MigrationProgress {
    [string]$Phase               # Scanning, Exporting, Transferring, Importing, Installing
    [string]$CurrentItem
    [int]$TotalItems
    [int]$CompletedItems
    [int]$FailedItems
    [double]$PercentComplete
    [string]$StatusMessage
}

# --- Functions ---

function Initialize-Environment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    # Load config
    $configPath = Join-Path $RootPath "Config\AppSettings.json"
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    # Convert to hashtable for easier manipulation
    $configHash = @{}
    $config.PSObject.Properties | ForEach-Object { $configHash[$_.Name] = $_.Value }
    $configHash['RootPath'] = $RootPath

    # Ensure log directory exists
    $logDir = Join-Path $RootPath $config.LogDirectory
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $configHash['LogPath'] = Join-Path $logDir "Win11Migrator_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    # Ensure migration package directory exists
    $pkgDir = Join-Path $RootPath $config.MigrationPackageDirectory
    if (-not (Test-Path $pkgDir)) {
        New-Item -Path $pkgDir -ItemType Directory -Force | Out-Null
    }
    $configHash['PackagePath'] = $pkgDir

    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "Win11Migrator requires PowerShell 5.1 or later. Current version: $($PSVersionTable.PSVersion)"
    }

    # Check OS
    $os = [System.Environment]::OSVersion
    if ($os.Platform -ne 'Win32NT') {
        throw "Win11Migrator requires Windows. Detected: $($os.Platform)"
    }

    # Check for winget
    $configHash['WingetAvailable'] = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

    # Check for chocolatey
    $configHash['ChocolateyAvailable'] = $null -ne (Get-Command choco -ErrorAction SilentlyContinue)

    # Check for USMT (Windows ADK)
    $configHash['USMTAvailable'] = $false
    $configHash['USMTPath'] = $null
    $usmtSearchPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\amd64",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\x86"
    )
    foreach ($usmtPath in $usmtSearchPaths) {
        $scanState = Join-Path $usmtPath 'scanstate.exe'
        if (Test-Path $scanState) {
            $configHash['USMTAvailable'] = $true
            $configHash['USMTPath'] = $usmtPath
            break
        }
    }

    return $configHash
}
