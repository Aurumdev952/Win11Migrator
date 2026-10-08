<#
========================================================================================================
    Title:          Win11Migrator - User Profile Path Discovery
    Filename:       Get-UserProfilePaths.ps1
    Description:    Discovers user profile directories including OneDrive-aware known folder redirections.
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
    Detects the current user's profile folder paths, accounting for OneDrive redirection.
.DESCRIPTION
    Reads HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders
    to resolve the real paths for Desktop, Documents, Downloads, Pictures, Videos, and Music.
    If OneDrive has redirected any of these, the OneDrive path is returned instead of
    the default %USERPROFILE% sub-folder.
.OUTPUTS
    [hashtable] Mapping of folder names to their resolved filesystem paths.
#>

function Get-UserProfilePaths {
    [CmdletBinding()]
    param()

    Write-MigrationLog -Message "Detecting user profile paths for $env:USERNAME" -Level Info

    $shellFoldersKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

    # Map of friendly names to their registry value names
    $folderMap = @{
        'Desktop'   = 'Desktop'
        'Documents' = 'Personal'
        'Downloads' = '{374DE290-123F-4565-9164-39C4925E467B}'
        'Pictures'  = 'My Pictures'
        'Videos'    = 'My Video'
        'Music'     = 'My Music'
        'Favorites' = 'Favorites'
    }

    # Known-folder GUIDs for fallback via SHGetKnownFolderPath (Downloads does not
    # always appear in the registry, so we use the Environment approach below).
    $defaultPaths = @{
        'Desktop'   = Join-Path $env:USERPROFILE 'Desktop'
        'Documents' = Join-Path $env:USERPROFILE 'Documents'
        'Downloads' = Join-Path $env:USERPROFILE 'Downloads'
        'Pictures'  = Join-Path $env:USERPROFILE 'Pictures'
        'Videos'    = Join-Path $env:USERPROFILE 'Videos'
        'Music'     = Join-Path $env:USERPROFILE 'Music'
        'Favorites' = Join-Path $env:USERPROFILE 'Favorites'
    }

    $result = @{}
    $oneDriveDetected = $false

    try {
        $regValues = Get-ItemProperty -Path $shellFoldersKey -ErrorAction Stop
    }
    catch {
        Write-MigrationLog -Message "Unable to read User Shell Folders registry key: $($_.Exception.Message)" -Level Warning
        $regValues = $null
    }

    foreach ($folderName in $folderMap.Keys) {
        $regValueName = $folderMap[$folderName]
        $resolvedPath = $null

        # Attempt to read from registry
        if ($regValues -and $regValues.PSObject.Properties[$regValueName]) {
            $rawPath = $regValues.$regValueName

            # Expand environment variables embedded in the registry value (e.g. %USERPROFILE%)
            $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($rawPath)
        }

        # Validate resolved path; fall back to default if it is empty or non-existent
        if (-not $resolvedPath -or -not (Test-Path $resolvedPath -ErrorAction SilentlyContinue)) {
            $resolvedPath = $defaultPaths[$folderName]
        }

        # Detect OneDrive redirection
        if ($resolvedPath -match 'OneDrive') {
            $oneDriveDetected = $true
            Write-MigrationLog -Message "OneDrive redirection detected for $folderName -> $resolvedPath" -Level Info
        }

        $result[$folderName] = $resolvedPath
        Write-MigrationLog -Message "Profile path: $folderName = $resolvedPath" -Level Debug
    }

    # Also capture the base user profile path for reference
    $result['UserProfile'] = $env:USERPROFILE
    $result['OneDriveRedirected'] = $oneDriveDetected

    if ($oneDriveDetected) {
        Write-MigrationLog -Message "OneDrive Known Folder Move is active for one or more folders" -Level Info
    }

    Write-MigrationLog -Message "User profile path detection complete" -Level Success
    return $result
}

function Get-DefaultUserDataItems {
    <#
    .SYNOPSIS
        UserDataItem for each standard profile folder that exists, with cloud-sync detection.
    .PARAMETER SkipCloudSynced
        Mark OneDrive / Google Drive folders to be left for the sync client instead of copied.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Folders = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'Favorites'),
        [switch]$SkipCloudSynced
    )

    $profilePaths = Get-UserProfilePaths
    $cloudFolders = Find-CloudSyncFolders
    $googleRoot = if ($cloudFolders.GoogleDriveAvailable -and $cloudFolders.GoogleDrivePath) { $cloudFolders.GoogleDrivePath.TrimEnd('\') } else { $null }

    foreach ($folder in $Folders) {
        $folderPath = $profilePaths[$folder]
        if (-not $folderPath) { $folderPath = Join-Path $env:USERPROFILE $folder }
        if (-not (Test-Path -LiteralPath $folderPath)) { continue }

        $item = [UserDataItem]::new()
        $item.SourcePath = $folderPath
        $item.RelativePath = $folder
        $item.Category = $folder
        $item.Selected = $true
        $isOneDrive = ($folderPath -match 'OneDrive')
        $isGoogleDrive = ($googleRoot -and ($folderPath -eq $googleRoot -or $folderPath -like "$googleRoot\*"))
        if ($isOneDrive -or $isGoogleDrive) {
            $item.IsCloudSynced = $true
            $item.CloudProvider = if ($isOneDrive) { 'OneDrive' } else { 'GoogleDrive' }
            $item.SkipCloudSync = [bool]$SkipCloudSynced
        }
        $item
    }
}
