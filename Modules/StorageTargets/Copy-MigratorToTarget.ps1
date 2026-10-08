<#
========================================================================================================
    Title:          Win11Migrator - Copy Migrator To Target
    Filename:       Copy-MigratorToTarget.ps1
    Description:    Copies the Win11Migrator tool itself alongside a migration package so it can
                    run directly on the target machine without separate installation.
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
    Copies Win11Migrator to a target directory so it can run on the target machine.
.DESCRIPTION
    Uses Robocopy /MIR to copy the essential Win11Migrator files (scripts, config, modules, GUI,
    reports) to a target base path. Excludes non-essential directories like MigrationPackage, Build,
    .git, and Tests. Skips the copy if the target already has the same or newer version.
.PARAMETER TargetBasePath
    The target directory where Win11Migrator files should be placed. For example,
    "E:\Win11Migrator" or "\\PC\C$\Users\john\Win11Migrator".
.OUTPUTS
    [PSCustomObject] With TargetPath, Copied, and Skipped properties.
.EXAMPLE
    Copy-MigratorToTarget -TargetBasePath "E:\Win11Migrator"
#>

function Copy-MigratorToTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetBasePath
    )

    Write-MigrationLog -Message "Bundling Win11Migrator tool to: $TargetBasePath" -Level Info

    $sourceVersion = Get-MigratorVersion -Root $script:MigratorRoot
    $targetVersion = Get-MigratorVersion -Root $TargetBasePath
    if ($sourceVersion -and $targetVersion -and $targetVersion -ge $sourceVersion) {
        Write-MigrationLog -Message "Target already has Win11Migrator v$targetVersion (source: v$sourceVersion) - skipping tool copy" -Level Info
        return [PSCustomObject]@{ TargetPath = $TargetBasePath; Copied = $false; Skipped = $true }
    }

    # Ensure target directory exists
    if (-not (Test-Path $TargetBasePath)) {
        New-Item -Path $TargetBasePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    # /MIR keeps the bundled tool exact; packages written next to it are protected by /XD Win11Migration_*
    $robocopyArgs = @(
        $script:MigratorRoot
        $TargetBasePath
        '/MIR'
        '/XD', 'MigrationPackage', 'Build', '.git', 'Tests', '.claude', '.github', 'node_modules', '.vscode', 'Logs', 'Win11Migration_*'
        '/XF', '*.log', '.gitignore', '.gitattributes', 'LICENSE', '*.md', '*.w11mcrypt'
        '/R:2'
        '/W:3'
        '/NP'
        '/NFL'
        '/NDL'
        '/NJH'
        '/NJS'
        '/COPY:DAT'
        '/DCOPY:T'
    )

    $null = & robocopy @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        Write-MigrationLog -Message "Robocopy failed bundling Win11Migrator (exit code: $exitCode)" -Level Warning
    } else {
        Write-MigrationLog -Message "Win11Migrator bundled to $TargetBasePath" -Level Success
    }
    return [PSCustomObject]@{ TargetPath = $TargetBasePath; Copied = ($exitCode -lt 8); Skipped = $false }
}

function Get-MigratorVersion {
    param([string]$Root)
    $settings = Join-Path (Join-Path $Root 'Config') 'AppSettings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return $null }
    try { return [version](Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).Version } catch { return $null }
}
